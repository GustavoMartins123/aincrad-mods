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

    struct WeakObjectPtr
    {
        std::int32_t object_index{-1};
        std::int32_t object_serial_number{0};
    };

    static_assert(sizeof(WeakObjectPtr) == 0x8);

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
                && memory_malloc && memory_free;
        }
    };

    Api g_api{};

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
        if (!guarded_set_weak_object(weak, actor)
            || weak.object_index < 0 || weak.object_serial_number <= 0)
        {
            return push_result(lua, false, "actor could not be converted to an exact weak identity");
        }
        void* resolved_actor = nullptr;
        if (!guarded_get_weak_object(weak, resolved_actor) || resolved_actor != actor)
        {
            return push_result(lua, false, "actor weak identity did not resolve to the issued address");
        }

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

            const LuaFunction register_enemy = &native_register_enemy;
            const std::string register_name = "WEDNativeRegisterEnemy";

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
                g_api.register_function(states[index], register_name, register_enemy);
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
