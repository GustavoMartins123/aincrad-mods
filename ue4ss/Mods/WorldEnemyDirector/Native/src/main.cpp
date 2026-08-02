#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include <Windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// This bridge intentionally binds to the exported ABI of the exact UE4SS build
// installed with the game (c838a8ac). It does not embed engine offsets or scan
// game memory. Every UFunction/property offset comes from live reflection and is
// checked against the generated ROD.hpp sizes before ProcessEvent is allowed.
namespace RC
{
    using StringType = std::wstring;
    using StringViewType = std::wstring_view;

    namespace GUI
    {
        class GUITab;
    }

    namespace LuaMadeSimple
    {
        class Lua;
    }

    // ABI mirror of Mod/CppUserModBase.hpp at UE4SS c838a8ac. The loader only
    // communicates through this vtable. Keeping the complete virtual order is
    // required even though this mod overrides just the current on_lua_start.
    class CppUserModBase
    {
      protected:
        std::vector<std::shared_ptr<GUI::GUITab>> GUITabs{};

      public:
        StringType ModName{};
        StringType ModVersion{};
        StringType ModDescription{};
        StringType ModAuthors{};
        StringType ModIntendedSDKVersion{};

        CppUserModBase() = default;
        virtual ~CppUserModBase() = default;

        virtual void on_update() {}
        virtual void on_unreal_init() {}
        virtual void on_ui_init() {}
        virtual void on_program_start() {}

        virtual void on_lua_start(
            StringViewType,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            std::vector<LuaMadeSimple::Lua*>&) {}
        virtual void on_lua_start(
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            std::vector<LuaMadeSimple::Lua*>&) {}
        virtual void on_lua_stop(
            StringViewType,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            std::vector<LuaMadeSimple::Lua*>&) {}
        virtual void on_lua_stop(
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            std::vector<LuaMadeSimple::Lua*>&) {}

        virtual void on_dll_load(StringViewType) {}
        virtual void render_tab() {}

        virtual void on_lua_start(
            StringViewType,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua*) {}
        virtual void on_lua_start(
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua*) {}
        virtual void on_lua_stop(
            StringViewType,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua*) {}
        virtual void on_lua_stop(
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua&,
            LuaMadeSimple::Lua*) {}

        virtual void on_cpp_mods_loaded() {}
    };
}

namespace
{
    using Lua = RC::LuaMadeSimple::Lua;
    using LuaFunction = int (*)(const Lua&);

    constexpr int kRODEnemiesOffset = 0x5B8;
    constexpr int kManagerEnemyGroupOffset = 0x3E0;
    constexpr int kEnemyListOffset = 0x90;
    constexpr int kObjectArraySize = 0x10;
    constexpr std::uint32_t kInternalFlagAsync = 0x04000000;

    // Distance-band scanning reads the actor position directly instead of
    // crossing the Lua boundary once per enemy. AActor::RootComponent and
    // USceneComponent::RelativeLocation come from the generated ROD/Engine
    // headers for this build; every offset is still re-verified through live
    // reflection before a single byte is read, exactly like the registry
    // injection path does.
    //
    // RelativeLocation is 0x18 wide because UE5 large-world coordinates make
    // FVector three doubles, not three floats. Reading it as float silently
    // yields garbage, so the size check below is load-bearing.
    constexpr int kRootComponentOffset = 0x1A0;
    constexpr int kAttachParentOffset = 0xB0;
    constexpr int kRelativeLocationOffset = 0x128;
    constexpr int kVectorSize = 0x18;

    constexpr std::int32_t kZoneUnknown = 0;
    constexpr std::int32_t kZoneActive = 1;
    constexpr std::int32_t kZoneDormant = 2;
    constexpr std::int32_t kZoneReleased = 3;

    struct WeakObjectPtr
    {
        std::int32_t object_index{-1};
        std::int32_t object_serial_number{0};
    };

    static_assert(sizeof(WeakObjectPtr) == 0x8);

    // The band an owned actor was last classified into travels with its weak
    // identity so a scan can report only the actors that actually changed band.
    struct OwnedActor
    {
        WeakObjectPtr weak{};
        std::int32_t zone{kZoneUnknown};
    };

    struct ZoneTransition
    {
        std::int64_t actor_address{};
        std::int32_t new_zone{kZoneUnknown};
        std::int32_t old_zone{kZoneUnknown};
    };

    // URODGameConfig::EnemyPoolingNum is TMap<EEnemyRole, int32>: how many
    // enemies the game keeps pooled per role. When that budget runs out the
    // game recycles an enemy that is still alive, which is what EnemyReused
    // fires on. A multiplied population is far larger than the pool was sized
    // for, so live extras get repurposed underneath us mid-fight and come back
    // half-initialised. Raising the budget is the fix, and it is the game's own
    // number rather than a bypass.
    //
    // A TMap is a TSet of key/value pairs over a sparse array. The offsets are
    // never guessed: FMapProperty::GetMapLayout gives the real element stride
    // and value offset for this build.
    struct ScriptSparseArrayLayout
    {
        std::int32_t element_offset{};
        std::int32_t alignment{};
        std::int32_t size{};
    };

    struct ScriptSetLayout
    {
        std::int32_t element_offset{};
        std::int32_t hash_next_id_offset{};
        std::int32_t hash_index_offset{};
        std::int32_t size{};
        ScriptSparseArrayLayout sparse_array_layout{};
    };

    struct ScriptMapLayout
    {
        std::int32_t key_offset{};
        std::int32_t value_offset{};
        ScriptSetLayout set_layout{};
    };

    struct ObjectArray
    {
        void** data{};
        std::int32_t count{};
        std::int32_t capacity{};
    };

    static_assert(sizeof(ObjectArray) == kObjectArraySize);

    struct Api
    {
        using RegisterFunction = void (*)(const Lua*, const std::string&, const LuaFunction&);
        using GetStackSize = std::int32_t (*)(const Lua*);
        using IsInteger = bool (*)(const Lua*, std::int32_t);
        using GetInteger = std::int64_t (*)(const Lua*, std::int32_t);
        using IsNumber = bool (*)(const Lua*, std::int32_t);
        using GetNumber = double (*)(const Lua*, std::int32_t);
        using SetBool = void (*)(const Lua*, bool);
        using SetInteger = void (*)(const Lua*, std::int64_t);
        using SetString = void (*)(const Lua*, const char*, std::size_t);
        using GetPropertyOffset = int (*)(const void*);
        using GetPropertySize = int (*)(const void*);
        using GetWeakObject = void* (*)(const WeakObjectPtr*);
        using SetWeakObject = void (*)(WeakObjectPtr*, const void*);
        using GetPropertyByNameInChain = void* (*)(void*, const wchar_t*);
        using MemoryMalloc = void* (*)(std::size_t, std::uint32_t);
        using MemoryFree = void (*)(void*);
        using GetNumElements = std::int32_t (*)();
        using IndexToObject = void* (*)(std::int32_t);
        using GetItemObject = void* (*)(const void*);
        using GetOuterPrivate = const void* const* (*)(const void*);
        using HasAnyInternalFlags = bool (*)(const void*, std::uint32_t);
        using UnsetInternalFlags = void (*)(void*, std::uint32_t);
        using SerialNumbersMatch = bool (*)(const WeakObjectPtr*, void*);
        using ObjectArrayLock = void (*)(void*);
        using GetMapLayout = ScriptMapLayout* (*)(void*);
        using GetMapValueProp = void** (*)(void*);

        HMODULE module{};
        RegisterFunction register_function{};
        GetStackSize get_stack_size{};
        IsInteger is_integer{};
        GetInteger get_integer{};
        IsNumber is_number{};
        GetNumber get_number{};
        SetBool set_bool{};
        SetInteger set_integer{};
        SetString set_string{};
        GetPropertyOffset get_property_offset{};
        GetPropertySize get_property_size{};
        GetWeakObject get_weak_object{};
        SetWeakObject set_weak_object{};
        GetPropertyByNameInChain get_property_by_name_in_chain{};
        MemoryMalloc memory_malloc{};
        MemoryFree memory_free{};
        GetNumElements get_num_elements{};
        IndexToObject index_to_object{};
        GetItemObject get_item_object{};
        GetOuterPrivate get_outer_private{};
        HasAnyInternalFlags has_any_internal_flags{};
        UnsetInternalFlags unset_internal_flags{};
        SerialNumbersMatch serial_numbers_match{};
        ObjectArrayLock lock_object_array{};
        ObjectArrayLock unlock_object_array{};
        GetMapLayout get_map_layout{};
        GetMapValueProp get_map_value_prop{};
        void** guobject_array_storage{};

        std::string missing_symbols{};
        bool loaded{};

        template <typename Function>
        void bind(Function& target, const char* symbol)
        {
            target = reinterpret_cast<Function>(GetProcAddress(module, symbol));
            if (target == nullptr)
            {
                if (!missing_symbols.empty()) missing_symbols += ", ";
                missing_symbols += symbol;
            }
        }

        void load()
        {
            if (loaded) return;
            loaded = true;
            module = GetModuleHandleW(L"UE4SS.dll");
            if (module == nullptr)
            {
                missing_symbols = "UE4SS.dll is not loaded";
                return;
            }

            bind(register_function,
                 "?register_function@Lua@LuaMadeSimple@RC@@QEBAXAEBV?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@AEBQ6AHAEBV123@@Z@Z");
            bind(get_stack_size, "?get_stack_size@Lua@LuaMadeSimple@RC@@QEBAHXZ");
            bind(is_integer, "?is_integer@Lua@LuaMadeSimple@RC@@QEBA_NH@Z");
            bind(get_integer, "?get_integer@Lua@LuaMadeSimple@RC@@QEBA_JH@Z");
            bind(is_number, "?is_number@Lua@LuaMadeSimple@RC@@QEBA_NH@Z");
            bind(get_number, "?get_number@Lua@LuaMadeSimple@RC@@QEBANH@Z");
            bind(set_bool, "?set_bool@Lua@LuaMadeSimple@RC@@QEBAX_N@Z");
            bind(set_integer, "?set_integer@Lua@LuaMadeSimple@RC@@QEBAX_J@Z");
            bind(set_string, "?set_string@Lua@LuaMadeSimple@RC@@QEBAXPEBD_K@Z");
            bind(get_property_offset, "?GetOffset_ForInternal@FProperty@Unreal@RC@@QEBAHXZ");
            bind(get_property_size, "?GetSize@FProperty@Unreal@RC@@QEBAHXZ");
            bind(get_weak_object, "?Get@FWeakObjectPtr@Unreal@RC@@QEBAPEAVUObject@23@XZ");
            bind(set_weak_object, "??4FWeakObjectPtr@Unreal@RC@@QEAAXPEBVUObject@12@@Z");
            bind(get_property_by_name_in_chain,
                 "?GetPropertyByNameInChain@UObject@Unreal@RC@@QEAAPEAVFProperty@23@PEB_W@Z");
            bind(memory_malloc, "?Malloc@FMemory@Unreal@RC@@SAPEAX_KI@Z");
            bind(memory_free, "?Free@FMemory@Unreal@RC@@SAXPEAX@Z");
            bind(get_num_elements, "?GetNumElements@FUObjectArray@Unreal@RC@@SAHXZ");
            bind(index_to_object, "?IndexToObject@FUObjectArray@Unreal@RC@@SAPEAUFUObjectItem@23@H@Z");
            bind(get_item_object, "?GetUObject@FUObjectItem@Unreal@RC@@QEBAPEAVUObject@23@XZ");
            bind(get_outer_private, "?GetOuterPrivate@UObjectBase@Unreal@RC@@QEBAAEAPEBVUObject@23@XZ");
            bind(has_any_internal_flags, "?HasAnyFlags@FUObjectItem@Unreal@RC@@QEBA_NW4EInternalObjectFlags@23@@Z");
            bind(unset_internal_flags, "?UnsetFlagsInternal@FUObjectItem@Unreal@RC@@AEAAXW4EInternalObjectFlags@23@@Z");
            bind(serial_numbers_match, "?SerialNumbersMatch@FWeakObjectPtr@Unreal@RC@@QEBA_NPEAUFUObjectItem@23@@Z");
            bind(lock_object_array, "?LockGUObjectArray@FUObjectArray@Unreal@RC@@QEAAXXZ");
            bind(unlock_object_array, "?UnlockGUObjectArray@FUObjectArray@Unreal@RC@@QEAAXXZ");
            bind(get_map_layout, "?GetMapLayout@FMapProperty@Unreal@RC@@QEAAAEAUFScriptMapLayout@23@XZ");
            bind(get_map_value_prop, "?GetValueProp@FMapProperty@Unreal@RC@@QEAAAEAPEAVFProperty@23@XZ");
            bind(guobject_array_storage, "?GUObjectArray@Unreal@RC@@3PEAVFUObjectArray@12@EA");
        }

        [[nodiscard]] bool lua_ready() const
        {
            return register_function && get_stack_size && is_integer && get_integer
                && is_number && get_number && set_bool && set_integer && set_string;
        }

        [[nodiscard]] bool unreal_ready() const
        {
            return get_property_offset && get_property_size
                && get_weak_object && set_weak_object
                && get_property_by_name_in_chain
                && memory_malloc && memory_free
                && get_num_elements && index_to_object && get_item_object
                && get_outer_private && has_any_internal_flags
                && unset_internal_flags && serial_numbers_match
                && lock_object_array && unlock_object_array
                && guobject_array_storage;
        }
    };

    Api g_api{};
    std::vector<OwnedActor> g_owned_actors{};
    std::vector<ZoneTransition> g_zone_transitions{};
    bool g_location_layout_verified{false};

    int push_result(
        const Lua& lua,
        bool ok,
        std::string_view detail,
        std::int64_t actor_address = 0,
        std::int64_t weak_index = -1,
        std::int64_t weak_serial = 0)
    {
        g_api.set_bool(&lua, ok);
        g_api.set_string(&lua, detail.data(), detail.size());
        g_api.set_integer(&lua, actor_address);
        g_api.set_integer(&lua, weak_index);
        g_api.set_integer(&lua, weak_serial);
        return 5;
    }

    bool require_integer(const Lua& lua, int index, std::int64_t& value)
    {
        if (g_api.is_integer(&lua, index))
        {
            value = g_api.get_integer(&lua, index);
            return true;
        }
        if (!g_api.is_number(&lua, index)) return false;
        const double number = g_api.get_number(&lua, index);
        if (!std::isfinite(number)
            || std::trunc(number) != number
            || std::abs(number) > 9007199254740991.0)
        {
            return false;
        }
        value = static_cast<std::int64_t>(number);
        return true;
    }

    bool guarded_get_weak_object(const WeakObjectPtr& weak, void*& actor)
    {
        __try
        {
            actor = g_api.get_weak_object(&weak);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            actor = nullptr;
            return false;
        }
    }

    bool guarded_set_weak_object(WeakObjectPtr& weak, const void* object)
    {
        __try
        {
            g_api.set_weak_object(&weak, object);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            weak = {};
            return false;
        }
    }

    bool guarded_get_object_array(void*& object_array)
    {
        __try
        {
            object_array = g_api.guobject_array_storage == nullptr
                ? nullptr
                : *g_api.guobject_array_storage;
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            object_array = nullptr;
            return false;
        }
    }

    bool guarded_lock_object_array(void* object_array)
    {
        __try
        {
            g_api.lock_object_array(object_array);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    bool guarded_unlock_object_array(void* object_array)
    {
        __try
        {
            g_api.unlock_object_array(object_array);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    bool guarded_get_num_elements(std::int32_t& count)
    {
        __try
        {
            count = g_api.get_num_elements();
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            count = 0;
            return false;
        }
    }

    bool guarded_index_to_object(std::int32_t index, void*& item)
    {
        __try
        {
            item = g_api.index_to_object(index);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            item = nullptr;
            return false;
        }
    }

    bool guarded_get_item_object(const void* item, void*& object)
    {
        __try
        {
            object = g_api.get_item_object(item);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            object = nullptr;
            return false;
        }
    }

    bool guarded_serial_numbers_match(
        const WeakObjectPtr& weak,
        void* item,
        bool& matches)
    {
        __try
        {
            matches = g_api.serial_numbers_match(&weak, item);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            matches = false;
            return false;
        }
    }

    bool guarded_get_outer(const void* object, void*& outer)
    {
        __try
        {
            const void* const* outer_reference = g_api.get_outer_private(object);
            outer = outer_reference == nullptr
                ? nullptr
                : const_cast<void*>(*outer_reference);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            outer = nullptr;
            return false;
        }
    }

    bool guarded_has_async_flag(const void* item, bool& has_async)
    {
        __try
        {
            has_async = g_api.has_any_internal_flags(item, kInternalFlagAsync);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            has_async = false;
            return false;
        }
    }

    bool guarded_unset_async_flag(void* item)
    {
        __try
        {
            g_api.unset_internal_flags(item, kInternalFlagAsync);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    // The failure reason is reported separately because these conditions mean
    // very different things. "Could not be converted to an exact weak identity"
    // was one message for all of them, which made an actor the game had already
    // destroyed indistinguishable from one that was merely not registered yet.
    bool exact_weak_identity(void* actor, WeakObjectPtr& weak, const char*& reason)
    {
        reason = "";
        if (!guarded_set_weak_object(weak, actor))
        {
            reason = "weak pointer assignment faulted";
            return false;
        }
        if (weak.object_index < 0)
        {
            reason = "actor is not present in the global object array";
            return false;
        }
        if (weak.object_serial_number <= 0)
        {
            reason = "actor has no serial number yet";
            return false;
        }

        void* resolved_actor = nullptr;
        if (!guarded_get_weak_object(weak, resolved_actor))
        {
            reason = "weak pointer resolution faulted";
            return false;
        }
        if (resolved_actor == nullptr)
        {
            // The usual cause: the actor was destroyed or marked for
            // destruction between being issued and being registered, so the
            // weak pointer legitimately refuses to resolve it.
            reason = "actor no longer resolves; it was destroyed or marked pending kill";
            return false;
        }
        if (resolved_actor != actor)
        {
            reason = "weak pointer resolved to a different actor";
            return false;
        }
        return true;
    }

    bool is_owned_actor_tracked(const WeakObjectPtr& weak)
    {
        return std::any_of(
            g_owned_actors.begin(),
            g_owned_actors.end(),
            [&weak](const OwnedActor& tracked) {
                return tracked.weak.object_index == weak.object_index
                    && tracked.weak.object_serial_number == weak.object_serial_number;
            });
    }

    int native_track_owned_enemy(const Lua& lua)
    {
        if (!g_api.unreal_ready())
            return push_result(lua, false, "UE4SS native ABI is incomplete: " + g_api.missing_symbols);
        if (g_api.get_stack_size(&lua) != 1)
            return push_result(lua, false, "WEDNativeTrackOwnedEnemy requires one actor address");

        std::int64_t actor_address{};
        if (!require_integer(lua, 1, actor_address) || actor_address <= 0)
            return push_result(lua, false, "WEDNativeTrackOwnedEnemy received an invalid Unreal address");

        auto* actor = reinterpret_cast<void*>(static_cast<std::uintptr_t>(actor_address));
        WeakObjectPtr weak{};
        const char* identity_reason = "";
        if (!exact_weak_identity(actor, weak, identity_reason))
            return push_result(lua, false, std::string("exact weak identity failed: ") + identity_reason);

        if (!is_owned_actor_tracked(weak))
            g_owned_actors.push_back(OwnedActor{weak, kZoneUnknown});
        return push_result(
            lua,
            true,
            "issued actor retained as a native weak identity until world teardown",
            actor_address,
            weak.object_index,
            weak.object_serial_number);
    }

    // Ownership used to be recorded by appending an FName to the actor's Tags
    // array from Lua. Appending to a native TArray through the Lua wrapper does
    // not append: it corrupts the array, and the tag then fails to read back on
    // the very next call. The weak identity registry already knows exactly
    // which actors this mod issued, so ownership is answered from that instead
    // and nothing writes to the actor at all.
    int native_identify_owned_enemy(const Lua& lua)
    {
        if (!g_api.unreal_ready())
            return push_result(lua, false, "UE4SS native ABI is incomplete: " + g_api.missing_symbols);
        if (g_api.get_stack_size(&lua) != 1)
            return push_result(lua, false, "WEDNativeIdentifyOwnedEnemy requires one actor address");

        std::int64_t actor_address{};
        if (!require_integer(lua, 1, actor_address) || actor_address <= 0)
            return push_result(lua, false, "WEDNativeIdentifyOwnedEnemy received an invalid Unreal address");

        auto* actor = reinterpret_cast<void*>(static_cast<std::uintptr_t>(actor_address));
        WeakObjectPtr weak{};
        const char* identity_reason = "";
        if (!exact_weak_identity(actor, weak, identity_reason))
            return push_result(lua, false, std::string("exact weak identity failed: ") + identity_reason);

        const bool owned = is_owned_actor_tracked(weak);
        return push_result(
            lua,
            true,
            owned
                ? "actor matches an issued native weak identity"
                : "actor is not an issued native weak identity",
            owned ? 1 : 0,
            weak.object_index,
            weak.object_serial_number);
    }

    int native_release_owned_world(const Lua& lua)
    {
        if (!g_api.unreal_ready())
            return push_result(lua, false, "UE4SS native ABI is incomplete: " + g_api.missing_symbols);
        if (g_api.get_stack_size(&lua) != 0)
            return push_result(lua, false, "WEDNativeReleaseOwnedWorld does not accept arguments");

        const std::int64_t tracked_count = static_cast<std::int64_t>(g_owned_actors.size());
        if (g_owned_actors.empty())
            return push_result(lua, true, "no issued actor weak identities were retained", 0, 0, 0);

        void* object_array = nullptr;
        if (!guarded_get_object_array(object_array) || object_array == nullptr)
            return push_result(lua, false, "GUObjectArray is unavailable", 0, 0, tracked_count);
        if (!guarded_lock_object_array(object_array))
            return push_result(lua, false, "GUObjectArray could not be locked", 0, 0, tracked_count);

        bool success = true;
        std::string failure{};
        std::int32_t object_count = 0;
        std::vector<void*> resolved_actors{};
        std::vector<OwnedActor> resolved_weak_actors{};
        std::vector<void*> async_items{};

        if (!guarded_get_num_elements(object_count)
            || object_count < 0 || object_count > 50000000)
        {
            success = false;
            failure = "GUObjectArray element count is invalid";
        }

        if (success)
        {
            resolved_actors.reserve(g_owned_actors.size());
            resolved_weak_actors.reserve(g_owned_actors.size());
            for (const OwnedActor& tracked : g_owned_actors)
            {
                const WeakObjectPtr& weak = tracked.weak;
                void* item = nullptr;
                bool serial_matches = false;
                void* actor = nullptr;
                if (!guarded_index_to_object(weak.object_index, item))
                {
                    success = false;
                    failure = "tracked actor index could not be resolved";
                    break;
                }
                if (item == nullptr) continue;
                if (!guarded_serial_numbers_match(weak, item, serial_matches))
                {
                    success = false;
                    failure = "tracked actor serial could not be verified";
                    break;
                }
                if (!serial_matches) continue;
                if (!guarded_get_item_object(item, actor))
                {
                    success = false;
                    failure = "tracked actor object could not be read";
                    break;
                }
                if (actor != nullptr)
                {
                    resolved_actors.push_back(actor);
                    // The band travels with the identity: a same-world teleport
                    // sanitizes without invalidating what the scan already knows.
                    resolved_weak_actors.push_back(tracked);
                }
            }
        }

        if (success && !resolved_actors.empty())
        {
            for (std::int32_t index = 0; index < object_count; ++index)
            {
                void* item = nullptr;
                void* object = nullptr;
                bool has_async = false;
                if (!guarded_index_to_object(index, item)
                    || (item != nullptr && !guarded_get_item_object(item, object))
                    || (item != nullptr && object != nullptr
                        && !guarded_has_async_flag(item, has_async)))
                {
                    success = false;
                    failure = "GUObjectArray entry could not be inspected";
                    break;
                }
                if (item == nullptr || object == nullptr || !has_async) continue;

                void* current = object;
                bool belongs_to_owned_actor = false;
                for (int depth = 0; depth < 64 && current != nullptr; ++depth)
                {
                    if (std::find(resolved_actors.begin(), resolved_actors.end(), current)
                        != resolved_actors.end())
                    {
                        belongs_to_owned_actor = true;
                        break;
                    }
                    void* outer = nullptr;
                    if (!guarded_get_outer(current, outer))
                    {
                        success = false;
                        failure = "async UObject outer chain could not be inspected";
                        break;
                    }
                    if (outer == current)
                    {
                        success = false;
                        failure = "async UObject outer chain is cyclic";
                        break;
                    }
                    current = outer;
                }
                if (!success) break;
                if (current != nullptr && !belongs_to_owned_actor)
                {
                    success = false;
                    failure = "async UObject outer chain exceeds the safety limit";
                    break;
                }
                if (belongs_to_owned_actor) async_items.push_back(item);
            }
        }

        if (success)
        {
            for (void* item : async_items)
            {
                bool remains_async = false;
                if (!guarded_unset_async_flag(item)
                    || !guarded_has_async_flag(item, remains_async)
                    || remains_async)
                {
                    success = false;
                    failure = "Async flag could not be cleared from an owned UObject";
                    break;
                }
            }
        }

        const bool unlocked = guarded_unlock_object_array(object_array);
        if (!unlocked)
        {
            success = false;
            failure = "GUObjectArray could not be unlocked";
        }
        if (!success)
        {
            return push_result(
                lua,
                false,
                failure,
                static_cast<std::int64_t>(resolved_actors.size()),
                static_cast<std::int64_t>(async_items.size()),
                tracked_count);
        }

        const std::int64_t resolved_count = static_cast<std::int64_t>(resolved_actors.size());
        const std::int64_t cleared_count = static_cast<std::int64_t>(async_items.size());
        // Weak identities do not retain UObjects. Keep the identities that are
        // still live so same-world teleports can sanitize the same actors again
        // if gameplay creates another Async child after this pass. Expired
        // identities are pruned by the exact index+serial resolution above.
        g_owned_actors = std::move(resolved_weak_actors);
        return push_result(
            lua,
            true,
            "cleared Async GC roots and retained live weak identities",
            resolved_count,
            cleared_count,
            tracked_count);
    }

    bool guarded_get_property(void* object, const wchar_t* name, void*& property)
    {
        __try
        {
            property = g_api.get_property_by_name_in_chain(object, name);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            property = nullptr;
            return false;
        }
    }

    bool guarded_read_object(void* object, int offset, void*& value)
    {
        __try
        {
            value = *reinterpret_cast<void**>(static_cast<std::byte*>(object) + offset);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            value = nullptr;
            return false;
        }
    }

    // Every offset used by the band scan is confirmed against live reflection
    // once per session before any raw read happens. A layout that disagrees
    // with the generated headers disables the scan instead of reading the
    // wrong bytes: Lua then simply receives no transitions and leaves every
    // enemy at full simulation, which is the pre-LOD behaviour.
    bool verify_location_layout(void* actor)
    {
        if (g_location_layout_verified) return true;

        void* root_property = nullptr;
        if (!guarded_get_property(actor, L"RootComponent", root_property)
            || root_property == nullptr
            || g_api.get_property_offset(root_property) != kRootComponentOffset
            || g_api.get_property_size(root_property) != static_cast<int>(sizeof(void*)))
        {
            return false;
        }

        void* root = nullptr;
        if (!guarded_read_object(actor, kRootComponentOffset, root) || root == nullptr)
            return false;

        void* location_property = nullptr;
        if (!guarded_get_property(root, L"RelativeLocation", location_property)
            || location_property == nullptr
            || g_api.get_property_offset(location_property) != kRelativeLocationOffset
            || g_api.get_property_size(location_property) != kVectorSize)
        {
            return false;
        }

        void* attach_property = nullptr;
        if (!guarded_get_property(root, L"AttachParent", attach_property)
            || attach_property == nullptr
            || g_api.get_property_offset(attach_property) != kAttachParentOffset
            || g_api.get_property_size(attach_property) != static_cast<int>(sizeof(void*)))
        {
            return false;
        }

        g_location_layout_verified = true;
        return true;
    }

    bool guarded_read_location(void* root, double& x, double& y, double& z)
    {
        __try
        {
            const auto* location = reinterpret_cast<const double*>(
                static_cast<std::byte*>(root) + kRelativeLocationOffset);
            x = location[0];
            y = location[1];
            z = location[2];
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            x = 0.0;
            y = 0.0;
            z = 0.0;
            return false;
        }
    }

    // Hysteresis is applied to the band the actor is already in: leaving costs
    // radius + hysteresis, entering costs radius - hysteresis. Without this an
    // enemy parked exactly on a radius flips band every scan and thrashes its
    // behaviour tree.
    std::int32_t classify_zone(
        double distance,
        std::int32_t previous,
        double combat_radius,
        double despawn_radius,
        double hysteresis)
    {
        const double combat_edge = previous == kZoneActive
            ? combat_radius + hysteresis
            : combat_radius - hysteresis;
        const double despawn_edge = previous == kZoneReleased
            ? despawn_radius - hysteresis
            : despawn_radius + hysteresis;

        if (distance <= combat_edge) return kZoneActive;
        if (distance <= despawn_edge) return kZoneDormant;
        return kZoneReleased;
    }

    int native_scan_owned_enemies(const Lua& lua)
    {
        if (!g_api.unreal_ready())
            return push_result(lua, false, "UE4SS native ABI is incomplete: " + g_api.missing_symbols);
        if (g_api.get_stack_size(&lua) != 5)
        {
            return push_result(lua, false,
                "WEDNativeScanOwnedEnemies requires hero X, hero Y, combat radius, despawn radius and hysteresis");
        }

        // Centimetres arrive as integers.
        //
        // These were read with is_number/get_number and every call was rejected
        // as non-finite, which left distance banding switched off for its whole
        // life without anything else noticing. The integer path is the one the
        // tracking and registry functions already use successfully against this
        // UE4SS build, and whole centimetres are far finer than any band edge
        // needs.
        std::int64_t hero_x_cm{};
        std::int64_t hero_y_cm{};
        std::int64_t combat_radius_cm{};
        std::int64_t despawn_radius_cm{};
        std::int64_t hysteresis_cm{};
        if (!require_integer(lua, 1, hero_x_cm)
            || !require_integer(lua, 2, hero_y_cm)
            || !require_integer(lua, 3, combat_radius_cm)
            || !require_integer(lua, 4, despawn_radius_cm)
            || !require_integer(lua, 5, hysteresis_cm))
        {
            return push_result(lua, false,
                "WEDNativeScanOwnedEnemies requires whole-centimetre integers");
        }

        const double hero_x = static_cast<double>(hero_x_cm);
        const double hero_y = static_cast<double>(hero_y_cm);
        const double combat_radius = static_cast<double>(combat_radius_cm);
        const double despawn_radius = static_cast<double>(despawn_radius_cm);
        const double hysteresis = static_cast<double>(hysteresis_cm);
        if (combat_radius <= 0.0 || despawn_radius <= combat_radius || hysteresis < 0.0)
            return push_result(lua, false, "WEDNativeScanOwnedEnemies received an invalid radius band");

        g_zone_transitions.clear();

        std::vector<OwnedActor> retained{};
        retained.reserve(g_owned_actors.size());
        std::int64_t scanned = 0;
        std::int64_t pruned = 0;

        for (const OwnedActor& tracked : g_owned_actors)
        {
            void* actor = nullptr;
            if (!guarded_get_weak_object(tracked.weak, actor) || actor == nullptr)
            {
                // The actor is gone. Dropping it here is what keeps the tracking
                // list from growing for a whole session.
                ++pruned;
                continue;
            }

            retained.push_back(tracked);

            if (!verify_location_layout(actor)) continue;

            void* root = nullptr;
            if (!guarded_read_object(actor, kRootComponentOffset, root) || root == nullptr)
                continue;

            // RelativeLocation only equals world location while the root has no
            // parent. An attached root is reported as nothing rather than as a
            // wrong position.
            void* attach_parent = nullptr;
            if (!guarded_read_object(root, kAttachParentOffset, attach_parent)) continue;
            if (attach_parent != nullptr) continue;

            double x{};
            double y{};
            double z{};
            if (!guarded_read_location(root, x, y, z)) continue;

            const double dx = x - hero_x;
            const double dy = y - hero_y;
            const double distance = std::sqrt(dx * dx + dy * dy);
            if (!std::isfinite(distance)) continue;

            ++scanned;
            const std::int32_t zone = classify_zone(
                distance, tracked.zone, combat_radius, despawn_radius, hysteresis);
            if (zone == tracked.zone) continue;

            retained.back().zone = zone;
            g_zone_transitions.push_back(ZoneTransition{
                static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(actor)),
                zone,
                tracked.zone});
        }

        g_owned_actors = std::move(retained);
        return push_result(
            lua,
            true,
            g_location_layout_verified
                ? "owned enemy bands scanned"
                : "owned enemy band layout is unavailable; no bands were classified",
            static_cast<std::int64_t>(g_zone_transitions.size()),
            scanned,
            pruned);
    }

    // The bound UE4SS Lua ABI exposes only scalar setters, so transitions are
    // drained one per call rather than returned as a table. That costs one
    // boundary crossing per changed enemy, which is the point of reporting
    // changes only: in steady state there are none.
    int native_next_zone_transition(const Lua& lua)
    {
        if (g_api.get_stack_size(&lua) != 0)
            return push_result(lua, false, "WEDNativeNextZoneTransition does not accept arguments");
        if (g_zone_transitions.empty())
            return push_result(lua, true, "no queued band transitions", 0, kZoneUnknown, kZoneUnknown);

        const ZoneTransition transition = g_zone_transitions.back();
        g_zone_transitions.pop_back();
        return push_result(
            lua,
            true,
            "band transition",
            transition.actor_address,
            transition.new_zone,
            transition.old_zone);
    }

    // Raise URODGameConfig::EnemyPoolingNum so the game keeps more enemies
    // pooled per role and stops recycling ones that are still alive.
    //
    // When that budget runs out the game reuses an enemy that is still in play,
    // which is what EnemyReused fires on. A multiplied population is far larger
    // than the pool was ever sized for, so live extras get repurposed
    // underneath us mid-fight and come back half-initialised.
    //
    // Only the int32 values are touched. No key is added, nothing is rehashed,
    // and the map's structure is never rewritten -- that is the difference
    // between adjusting the game's own budget and corrupting a native
    // container. Offsets are not guessed either: FMapProperty::GetMapLayout
    // gives the real element stride and value offset for this build.
    //
    // The SEH block lives in its own function because a function that needs C++
    // object unwinding cannot use __try.
    bool guarded_raise_pool_budget(
        void* config,
        void* map_property,
        std::int64_t multiplier,
        std::int64_t& raised,
        std::int64_t& total_before,
        std::int64_t& total_after,
        const char*& failure)
    {
        __try
        {
            const int map_offset = g_api.get_property_offset(map_property);
            if (map_offset <= 0)
            {
                failure = "EnemyPoolingNum has no usable offset";
                return false;
            }

            const ScriptMapLayout* layout = g_api.get_map_layout(map_property);
            void** value_prop_ref = g_api.get_map_value_prop(map_property);
            void* value_prop = value_prop_ref == nullptr ? nullptr : *value_prop_ref;
            if (layout == nullptr || value_prop == nullptr
                || g_api.get_property_size(value_prop) != static_cast<int>(sizeof(std::int32_t)))
            {
                failure = "EnemyPoolingNum is not a map of 32-bit values";
                return false;
            }

            // A TMap begins with its sparse array, whose first member has the
            // same data/count/capacity shape as any TArray.
            auto* pairs = reinterpret_cast<ObjectArray*>(
                static_cast<std::byte*>(config) + map_offset);
            const std::int32_t stride = layout->set_layout.sparse_array_layout.size;
            const std::int32_t value_offset = layout->value_offset;

            if (stride <= 0 || stride > 4096
                || value_offset < 0 || value_offset + 4 > stride
                || pairs->count < 0 || pairs->count > 4096
                || pairs->capacity < pairs->count
                || (pairs->count > 0 && pairs->data == nullptr))
            {
                failure = "EnemyPoolingNum layout is outside its expected bounds";
                return false;
            }

            auto* base = reinterpret_cast<std::byte*>(pairs->data);
            for (std::int32_t index = 0; index < pairs->count; ++index)
            {
                auto* value = reinterpret_cast<std::int32_t*>(
                    base + static_cast<std::size_t>(index) * stride + value_offset);
                const std::int32_t before = *value;
                // Free slots in the sparse array hold link data, so only values
                // that look like a real pool size are touched.
                if (before <= 0 || before > 4096) continue;
                const std::int64_t scaled =
                    static_cast<std::int64_t>(before) * multiplier;
                const std::int32_t after = static_cast<std::int32_t>(
                    scaled > 8192 ? 8192 : scaled);
                total_before += before;
                total_after += after;
                if (after != before)
                {
                    *value = after;
                    ++raised;
                }
            }
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            failure = "EnemyPoolingNum could not be read or written";
            return false;
        }
    }

    int native_expand_enemy_pool(const Lua& lua)
    {
        if (!g_api.unreal_ready())
            return push_result(lua, false, "UE4SS native ABI is incomplete: " + g_api.missing_symbols);
        if (g_api.get_map_layout == nullptr || g_api.get_map_value_prop == nullptr)
            return push_result(lua, false, "this UE4SS build does not expose FMapProperty layout access");
        if (g_api.get_stack_size(&lua) != 2)
            return push_result(lua, false, "WEDNativeExpandEnemyPool requires a game config address and a multiplier");

        std::int64_t config_address{};
        std::int64_t multiplier{};
        if (!require_integer(lua, 1, config_address) || config_address <= 0
            || !require_integer(lua, 2, multiplier)
            || multiplier < 1 || multiplier > 64)
        {
            return push_result(lua, false, "WEDNativeExpandEnemyPool received an invalid address or multiplier");
        }

        auto* config = reinterpret_cast<void*>(static_cast<std::uintptr_t>(config_address));
        void* map_property = nullptr;
        if (!guarded_get_property(config, L"EnemyPoolingNum", map_property)
            || map_property == nullptr)
        {
            return push_result(lua, false, "URODGameConfig does not expose EnemyPoolingNum");
        }

        std::int64_t raised = 0;
        std::int64_t total_before = 0;
        std::int64_t total_after = 0;
        const char* failure = "";
        if (!guarded_raise_pool_budget(config, map_property, multiplier,
                raised, total_before, total_after, failure))
        {
            return push_result(lua, false, failure);
        }
        return push_result(lua, true, "enemy pool budget raised",
            raised, total_before, total_after);
    }

    enum class ArrayRegistrationResult
    {
        success,
        invalid_array,
        already_registered,
        allocation_failed,
        access_violation,
    };

    ArrayRegistrationResult register_in_both_arrays(
        ObjectArray* enemies,
        ObjectArray* grouped,
        void* actor,
        bool& added_to_enemies,
        bool& added_to_grouped)
    {
        added_to_enemies = false;
        added_to_grouped = false;
        void** new_enemies = nullptr;
        void** new_grouped = nullptr;
        void** old_enemies = nullptr;
        void** old_grouped = nullptr;
        bool enemies_replaced = false;
        bool grouped_replaced = false;

        __try
        {
            const auto valid = [](const ObjectArray* array) {
                return array != nullptr
                    && array->count >= 0
                    && array->capacity >= array->count
                    && array->capacity <= 1048576
                    && (array->capacity == 0 || array->data != nullptr);
            };
            if (!valid(enemies) || !valid(grouped))
                return ArrayRegistrationResult::invalid_array;

            const auto contains = [actor](const ObjectArray* array) {
                for (std::int32_t index = 0; index < array->count; ++index)
                    if (array->data[index] == actor) return true;
                return false;
            };
            const bool in_enemies = contains(enemies);
            const bool in_grouped = contains(grouped);
            if (in_enemies && in_grouped)
                return ArrayRegistrationResult::already_registered;
            const bool needs_enemies = !in_enemies;
            const bool needs_grouped = !in_grouped;

            auto next_capacity = [](const ObjectArray* array) {
                if (array->count < array->capacity) return array->capacity;
                const std::int64_t grown = array->capacity == 0
                    ? 4
                    : static_cast<std::int64_t>(array->capacity)
                        + array->capacity / 2 + 4;
                return static_cast<std::int32_t>(std::max<std::int64_t>(
                    grown, static_cast<std::int64_t>(array->count) + 1));
            };
            const std::int32_t enemies_capacity = needs_enemies
                ? next_capacity(enemies) : enemies->capacity;
            const std::int32_t grouped_capacity = needs_grouped
                ? next_capacity(grouped) : grouped->capacity;

            if (needs_enemies && enemies_capacity != enemies->capacity)
            {
                new_enemies = static_cast<void**>(g_api.memory_malloc(
                    static_cast<std::size_t>(enemies_capacity) * sizeof(void*),
                    alignof(void*)));
                if (new_enemies == nullptr)
                    return ArrayRegistrationResult::allocation_failed;
                if (enemies->count > 0)
                    std::memcpy(new_enemies, enemies->data,
                        static_cast<std::size_t>(enemies->count) * sizeof(void*));
            }
            if (needs_grouped && grouped_capacity != grouped->capacity)
            {
                new_grouped = static_cast<void**>(g_api.memory_malloc(
                    static_cast<std::size_t>(grouped_capacity) * sizeof(void*),
                    alignof(void*)));
                if (new_grouped == nullptr)
                {
                    if (new_enemies != nullptr) g_api.memory_free(new_enemies);
                    return ArrayRegistrationResult::allocation_failed;
                }
                if (grouped->count > 0)
                    std::memcpy(new_grouped, grouped->data,
                        static_cast<std::size_t>(grouped->count) * sizeof(void*));
            }

            void** enemies_destination = new_enemies != nullptr
                ? new_enemies : enemies->data;
            void** grouped_destination = new_grouped != nullptr
                ? new_grouped : grouped->data;
            if (needs_enemies) enemies_destination[enemies->count] = actor;
            if (needs_grouped) grouped_destination[grouped->count] = actor;

            if (new_enemies != nullptr)
            {
                old_enemies = enemies->data;
                enemies->data = new_enemies;
                enemies->capacity = enemies_capacity;
                enemies_replaced = true;
            }
            if (new_grouped != nullptr)
            {
                old_grouped = grouped->data;
                grouped->data = new_grouped;
                grouped->capacity = grouped_capacity;
                grouped_replaced = true;
            }
            if (needs_enemies) ++enemies->count;
            if (needs_grouped) ++grouped->count;
            added_to_enemies = needs_enemies;
            added_to_grouped = needs_grouped;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            if (!enemies_replaced && new_enemies != nullptr)
                g_api.memory_free(new_enemies);
            if (!grouped_replaced && new_grouped != nullptr)
                g_api.memory_free(new_grouped);
            return ArrayRegistrationResult::access_violation;
        }

        if (enemies_replaced && old_enemies != nullptr) g_api.memory_free(old_enemies);
        if (grouped_replaced && old_grouped != nullptr) g_api.memory_free(old_grouped);
        return ArrayRegistrationResult::success;
    }

    int native_register_enemy(const Lua& lua)
    {
        if (!g_api.unreal_ready())
            return push_result(lua, false, "UE4SS native ABI is incomplete: " + g_api.missing_symbols);
        if (g_api.get_stack_size(&lua) != 2)
            return push_result(lua, false, "WEDNativeRegisterEnemy requires game state and actor addresses");

        std::int64_t actor_address{};
        std::int64_t game_state_address{};
        if (!require_integer(lua, 2, actor_address)
            || !require_integer(lua, 1, game_state_address)
            || actor_address <= 0 || game_state_address <= 0)
        {
            return push_result(lua, false, "WEDNativeRegisterEnemy received an invalid Unreal address");
        }
        auto* actor = reinterpret_cast<void*>(static_cast<std::uintptr_t>(actor_address));
        auto* game_state = reinterpret_cast<void*>(static_cast<std::uintptr_t>(game_state_address));

        WeakObjectPtr weak{};
        const char* identity_reason = "";
        if (!exact_weak_identity(actor, weak, identity_reason))
            return push_result(lua, false, std::string("exact weak identity failed: ") + identity_reason);
        if (!is_owned_actor_tracked(weak))
            return push_result(lua, false, "actor was not tracked before native registry injection");

        void* enemies_property = nullptr;
        void* group_property = nullptr;
        if (!guarded_get_property(game_state, L"RODEnemies", enemies_property)
            || !guarded_get_property(game_state, L"ManagerEnemyGroup", group_property)
            || enemies_property == nullptr || group_property == nullptr)
        {
            return push_result(lua, false, "ARODGameState registry properties are unavailable");
        }
        if (g_api.get_property_offset(enemies_property) != kRODEnemiesOffset
            || g_api.get_property_size(enemies_property) != kObjectArraySize
            || g_api.get_property_offset(group_property) != kManagerEnemyGroupOffset
            || g_api.get_property_size(group_property) != static_cast<int>(sizeof(void*)))
        {
            return push_result(lua, false, "ARODGameState registry layout differs from ROD.hpp");
        }

        void* group = nullptr;
        if (!guarded_read_object(game_state, kManagerEnemyGroupOffset, group)
            || group == nullptr)
        {
            return push_result(lua, false, "ManagerEnemyGroup is unavailable");
        }
        void* enemy_list_property = nullptr;
        if (!guarded_get_property(group, L"EnemyList", enemy_list_property)
            || enemy_list_property == nullptr
            || g_api.get_property_offset(enemy_list_property) != kEnemyListOffset
            || g_api.get_property_size(enemy_list_property) != kObjectArraySize)
        {
            return push_result(lua, false, "URODAIEnemyGroup registry layout differs from ROD.hpp");
        }

        auto* enemies = reinterpret_cast<ObjectArray*>(
            static_cast<std::byte*>(game_state) + kRODEnemiesOffset);
        auto* grouped = reinterpret_cast<ObjectArray*>(
            static_cast<std::byte*>(group) + kEnemyListOffset);
        bool added_to_enemies = false;
        bool added_to_grouped = false;
        const ArrayRegistrationResult registered = register_in_both_arrays(
            enemies, grouped, actor, added_to_enemies, added_to_grouped);
        if (registered != ArrayRegistrationResult::success)
        {
            const char* detail = "native registry mutation failed";
            switch (registered)
            {
            case ArrayRegistrationResult::invalid_array:
                detail = "native enemy registry array is invalid"; break;
            case ArrayRegistrationResult::already_registered:
                detail = "issued actor was already present in both native registries"; break;
            case ArrayRegistrationResult::allocation_failed:
                detail = "native enemy registry allocation failed"; break;
            case ArrayRegistrationResult::access_violation:
                detail = "native enemy registry memory access failed"; break;
            default: break;
            }
            return push_result(lua, false, detail, 0,
                weak.object_index, weak.object_serial_number);
        }

        const char* detail = added_to_enemies && added_to_grouped
            ? "issued actor added to RODEnemies and EnemyList outside the native pool"
            : added_to_enemies
                ? "issued actor already had EnemyList; added to RODEnemies outside the native pool"
                : "issued actor already had RODEnemies; added to EnemyList outside the native pool";
        return push_result(lua, true, detail,
            actor_address, weak.object_index, weak.object_serial_number);
    }

    class WorldEnemyDirectorNative final : public RC::CppUserModBase
    {
      public:
        WorldEnemyDirectorNative()
        {
            ModName = L"WorldEnemyDirectorNative";
            ModVersion = L"1.8.1";
            ModDescription = L"Direct enemy registry bridge outside the native spawn pool";
            ModAuthors = L"WorldEnemyDirector";
            ModIntendedSDKVersion = L"3.0.1";
            g_api.load();
        }

        void on_lua_start(Lua& lua, Lua& main_lua, Lua& async_lua, Lua* hook_lua) override
        {
            if (!g_api.lua_ready()) return;

            const LuaFunction track_owned_enemy = &native_track_owned_enemy;
            const LuaFunction identify_owned_enemy = &native_identify_owned_enemy;
            const LuaFunction register_enemy = &native_register_enemy;
            const LuaFunction release_owned_world = &native_release_owned_world;
            const LuaFunction scan_owned_enemies = &native_scan_owned_enemies;
            const LuaFunction expand_enemy_pool = &native_expand_enemy_pool;
            const LuaFunction next_zone_transition = &native_next_zone_transition;
            const std::string track_name = "WEDNativeTrackOwnedEnemy";
            const std::string identify_name = "WEDNativeIdentifyOwnedEnemy";
            const std::string register_name = "WEDNativeRegisterEnemy";
            const std::string release_name = "WEDNativeReleaseOwnedWorld";
            const std::string scan_name = "WEDNativeScanOwnedEnemies";
            const std::string expand_name = "WEDNativeExpandEnemyPool";
            const std::string transition_name = "WEDNativeNextZoneTransition";

            std::vector<Lua*> states{&lua, &main_lua, &async_lua};
            if (hook_lua != nullptr) states.push_back(hook_lua);
            for (std::size_t index = 0; index < states.size(); ++index)
            {
                bool duplicate = false;
                for (std::size_t previous = 0; previous < index; ++previous)
                {
                    if (states[previous] == states[index])
                    {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                g_api.register_function(states[index], track_name, track_owned_enemy);
                g_api.register_function(states[index], identify_name, identify_owned_enemy);
                g_api.register_function(states[index], register_name, register_enemy);
                g_api.register_function(states[index], release_name, release_owned_world);
                g_api.register_function(states[index], scan_name, scan_owned_enemies);
                g_api.register_function(states[index], expand_name, expand_enemy_pool);
                g_api.register_function(states[index], transition_name, next_zone_transition);
            }
        }
    };
}

extern "C" __declspec(dllexport) RC::CppUserModBase* start_mod()
{
    return new WorldEnemyDirectorNative();
}

extern "C" __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod)
{
    delete mod;
}
