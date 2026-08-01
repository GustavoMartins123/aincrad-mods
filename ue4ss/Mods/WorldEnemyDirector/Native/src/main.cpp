#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include <Windows.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
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

    constexpr std::uint64_t CPF_Parm = 0x0000000000000080ULL;
    constexpr std::uint64_t CPF_ReturnParm = 0x0000000000000400ULL;
    constexpr int kExpectedParameterCount = 7;
    constexpr int kTransformSize = 0x60;
    constexpr int kSpawnOptionSize = 0x88;
    constexpr int kSpawnResultSize = 0x10;
    constexpr int kFixedSpawnArguments = 6;
    constexpr int kPathChunkBytes = 7;
    constexpr int kMaxClassPathBytes = 1024;
    constexpr const char* kOwnedTag = "WorldEnemyDirectorOwned";

    struct WeakObjectPtr
    {
        std::int32_t object_index{-1};
        std::int32_t object_serial_number{0};
    };

    static_assert(sizeof(WeakObjectPtr) == 0x8);

    struct SpawnResult
    {
        std::uint8_t spawn_on{};
        std::uint8_t padding[3]{};
        WeakObjectPtr server_spawn_actor{};
        std::int32_t client_spawn_actor{};
    };

    static_assert(sizeof(SpawnResult) == kSpawnResultSize);

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
        using GetParmsSize = const std::uint16_t* (*)(const void*);
        using GetStructureSize = int (*)(const void*);
        using InitializeStruct = void (*)(const void*, void*, int);
        using DestroyStruct = void (*)(const void*, void*, int);
        using GetFirstProperty = void* (*)(void*);
        using GetNextField = void** (*)(void*);
        using GetPropertyOffset = int (*)(const void*);
        using GetPropertySize = int (*)(const void*);
        using HasAnyPropertyFlags = bool (*)(const void*, std::uint64_t);
        using ImportTextDirect = const wchar_t* (*)(
            const void*, const wchar_t*, void*, void*, int, void*);
        using SetObjectPropertyValue = void (*)(const void*, void*, void*);
        using ProcessEvent = void (*)(void*, void*, void*);
        using GetFunctionByNameInChain = void* (*)(void*, const wchar_t*);
        using GetWeakObject = void* (*)(const WeakObjectPtr*);
        using FindObject = void* (*)(void*, void*, const wchar_t*, bool, void*);

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
        GetParmsSize get_parms_size{};
        GetStructureSize get_structure_size{};
        InitializeStruct initialize_struct{};
        DestroyStruct destroy_struct{};
        GetFirstProperty get_first_property{};
        GetNextField get_next_field{};
        GetPropertyOffset get_property_offset{};
        GetPropertySize get_property_size{};
        HasAnyPropertyFlags has_any_property_flags{};
        ImportTextDirect import_text_direct{};
        SetObjectPropertyValue set_object_property_value{};
        ProcessEvent process_event{};
        GetFunctionByNameInChain get_function_by_name_in_chain{};
        GetWeakObject get_weak_object{};
        FindObject find_object{};

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
            bind(get_parms_size, "?GetParmsSize@UFunction@Unreal@RC@@QEBAAEBGXZ");
            bind(get_structure_size, "?GetStructureSize@UStruct@Unreal@RC@@QEBAHXZ");
            bind(initialize_struct, "?InitializeStruct@UStruct@Unreal@RC@@QEBAXPEAXH@Z");
            bind(destroy_struct, "?DestroyStruct@UStruct@Unreal@RC@@QEBAXPEAXH@Z");
            bind(get_first_property, "?GetFirstProperty@UStruct@Unreal@RC@@QEAAPEAVFProperty@23@XZ");
            bind(get_next_field, "?GetNext@FField@Unreal@RC@@AEAAAEAPEAV123@XZ");
            bind(get_property_offset, "?GetOffset_ForInternal@FProperty@Unreal@RC@@QEBAHXZ");
            bind(get_property_size, "?GetSize@FProperty@Unreal@RC@@QEBAHXZ");
            bind(has_any_property_flags, "?HasAnyPropertyFlags@FProperty@Unreal@RC@@QEBA_N_K@Z");
            bind(import_text_direct,
                 "?ImportText_Direct@FProperty@Unreal@RC@@QEBAPEB_WPEB_WPEAXPEAVUObject@23@HPEAVFOutputDevice@23@@Z");
            bind(set_object_property_value,
                 "?SetObjectPropertyValue@FObjectPropertyBase@Unreal@RC@@QEBAXPEAXPEAVUObject@23@@Z");
            bind(process_event, "?ProcessEvent@UObject@Unreal@RC@@QEAAXPEAVUFunction@23@PEAX@Z");
            bind(get_function_by_name_in_chain,
                 "?GetFunctionByNameInChain@UObject@Unreal@RC@@QEAAPEAVUFunction@23@PEB_W@Z");
            bind(get_weak_object, "?Get@FWeakObjectPtr@Unreal@RC@@QEBAPEAVUObject@23@XZ");
            bind(find_object,
                 "?FindObject@UObjectGlobals@Unreal@RC@@YAPEAVUObject@23@PEAVUClass@23@PEAV423@PEB_W_NPEAUObjectSearcher@23@@Z");
        }

        [[nodiscard]] bool lua_ready() const
        {
            return register_function && get_stack_size && is_integer && get_integer
                && is_number && get_number && set_bool && set_integer && set_string;
        }

        [[nodiscard]] bool unreal_ready() const
        {
            return get_parms_size && get_structure_size
                && initialize_struct && destroy_struct
                && get_first_property && get_next_field && get_property_offset
                && get_property_size && has_any_property_flags
                && import_text_direct && set_object_property_value
                && process_event && get_function_by_name_in_chain
                && get_weak_object && find_object;
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

    bool require_number(const Lua& lua, int index, double& value)
    {
        if (!g_api.is_number(&lua, index)) return false;
        value = g_api.get_number(&lua, index);
        return std::isfinite(value);
    }

    struct PropertyView
    {
        void* property{};
        int offset{-1};
        int size{};
        bool is_return{};
    };

    using PropertyList = std::vector<PropertyView>;

    bool read_function_contract(
        void* function,
        int parms_size,
        PropertyList& properties,
        std::string& error)
    {
        int previous_end = 0;
        for (void* property = g_api.get_first_property(function);
             property != nullptr;)
        {
            const int offset = g_api.get_property_offset(property);
            const int size = g_api.get_property_size(property);
            const bool is_parm = g_api.has_any_property_flags(property, CPF_Parm);
            const bool is_return = g_api.has_any_property_flags(property, CPF_ReturnParm);

            if (!is_parm)
            {
                error = "RODSpawnActor contains a reflected field without CPF_Parm";
                return false;
            }
            if (offset < previous_end || size <= 0 || offset + size > parms_size)
            {
                error = "RODSpawnActor returned an invalid reflected property range";
                return false;
            }
            properties.push_back(PropertyView{property, offset, size, is_return});
            previous_end = offset + size;

            void** next_storage = g_api.get_next_field(property);
            property = next_storage ? *next_storage : nullptr;
        }

        if (properties.size() != kExpectedParameterCount)
        {
            error = "RODSpawnActor parameter count differs from the generated header";
            return false;
        }
        return true;
    }

    bool require_property(
        const PropertyList& properties,
        std::size_t index,
        int expected_size,
        bool expected_return,
        PropertyView& result,
        std::string& error)
    {
        if (index >= properties.size())
        {
            error = "RODSpawnActor is missing a generated-header parameter";
            return false;
        }
        result = properties[index];
        if (result.size != expected_size || result.is_return != expected_return)
        {
            error = "RODSpawnActor parameter size/flags differ from the generated header";
            return false;
        }
        return true;
    }

    bool import_exact(
        const PropertyView& property,
        void* params,
        void* owner,
        const std::wstring& text,
        std::string& error)
    {
        auto* destination = static_cast<std::byte*>(params) + property.offset;
        const wchar_t* end = g_api.import_text_direct(
            property.property, text.c_str(), destination, owner, 0, nullptr);
        if (end == nullptr)
        {
            error = "Unreal reflection rejected a native spawn parameter";
            return false;
        }
        while (*end == L' ' || *end == L'\t' || *end == L'\r' || *end == L'\n') ++end;
        if (*end != L'\0')
        {
            error = "Unreal reflection only partially consumed a native spawn parameter";
            return false;
        }
        return true;
    }

    std::wstring transform_text(double x, double y, double z)
    {
        std::wostringstream out;
        out.imbue(std::locale::classic());
        out << std::setprecision(17)
            << L"(Rotation=(X=0,Y=0,Z=0,W=1),Translation=(X=" << x
            << L",Y=" << y << L",Z=" << z
            << L"),Scale3D=(X=1,Y=1,Z=1))";
        return out.str();
    }

    std::wstring option_text(double x, double y, double z, std::int32_t level)
    {
        std::wostringstream out;
        out.imbue(std::locale::classic());
        out << std::setprecision(17)
            << L"(ActorTags=(" << kOwnedTag
            << L"),DefaultSpawnOn=Server,Level=" << level
            << L",InitialState=Prowl,InitialStateLoc=(X=" << x
            << L",Y=" << y << L",Z=" << z
            << L"),IsNodetect=False,IsStartBehaviorTree=True,"
               L"IsForcePlaySpawnFX=False)";
        return out.str();
    }

    bool guarded_process_event(void* object, void* function, void* params)
    {
        __try
        {
            g_api.process_event(object, function, params);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    int native_spawn(const Lua& lua)
    {
        if (!g_api.unreal_ready())
        {
            return push_result(lua, false, "UE4SS native ABI is incomplete: " + g_api.missing_symbols);
        }
        const int stack_size = g_api.get_stack_size(&lua);
        const int maximum_stack_size = kFixedSpawnArguments
            + (kMaxClassPathBytes + kPathChunkBytes - 1) / kPathChunkBytes;
        if (stack_size <= kFixedSpawnArguments || stack_size > maximum_stack_size)
        {
            return push_result(lua, false, "WEDNativeSpawn received an invalid packed path size");
        }

        std::int64_t game_state_address{};
        std::int64_t level_value{};
        std::int64_t path_length_value{};
        double x{};
        double y{};
        double z{};
        // LuaMadeSimple get_* removes the value from the Lua stack. Consume
        // arguments right-to-left so every forced index remains stable.
        const int chunk_count = stack_size - kFixedSpawnArguments;
        std::vector<std::uint64_t> path_chunks(static_cast<std::size_t>(chunk_count));
        for (int chunk_index = chunk_count - 1; chunk_index >= 0; --chunk_index)
        {
            std::int64_t chunk_value{};
            const int stack_index = kFixedSpawnArguments + 1 + chunk_index;
            if (!require_integer(lua, stack_index, chunk_value)
                || chunk_value < 0
                || static_cast<std::uint64_t>(chunk_value) > 0x00FFFFFFFFFFFFFFULL)
            {
                return push_result(lua, false, "WEDNativeSpawn path chunk is not an exact 56-bit integer");
            }
            path_chunks[static_cast<std::size_t>(chunk_index)] =
                static_cast<std::uint64_t>(chunk_value);
        }
        if (!require_integer(lua, 6, path_length_value))
            return push_result(lua, false, "WEDNativeSpawn path length is not an exact integer");
        if (!require_number(lua, 5, z))
            return push_result(lua, false, "WEDNativeSpawn Z coordinate is invalid");
        if (!require_number(lua, 4, y))
            return push_result(lua, false, "WEDNativeSpawn Y coordinate is invalid");
        if (!require_number(lua, 3, x))
            return push_result(lua, false, "WEDNativeSpawn X coordinate is invalid");
        if (!require_integer(lua, 2, level_value))
            return push_result(lua, false, "WEDNativeSpawn level is not an exact integer");
        if (!require_integer(lua, 1, game_state_address))
            return push_result(lua, false, "WEDNativeSpawn game-state address is not an exact integer");
        if (game_state_address <= 0)
        {
            return push_result(lua, false, "WEDNativeSpawn received a null Unreal address");
        }
        if (path_length_value <= 0 || path_length_value > kMaxClassPathBytes)
        {
            return push_result(lua, false, "WEDNativeSpawn path length is outside the native contract");
        }
        const std::size_t path_length = static_cast<std::size_t>(path_length_value);
        const std::size_t expected_chunk_count =
            (path_length + kPathChunkBytes - 1) / kPathChunkBytes;
        if (path_chunks.size() != expected_chunk_count)
        {
            return push_result(lua, false, "WEDNativeSpawn packed path length does not match its chunks");
        }

        std::string class_path_utf8(path_length, '\0');
        for (std::size_t index = 0; index < path_length; ++index)
        {
            const std::uint64_t chunk = path_chunks[index / kPathChunkBytes];
            const unsigned char character = static_cast<unsigned char>(
                (chunk >> (8 * (index % kPathChunkBytes))) & 0xFFULL);
            if (character == 0 || character > 0x7f)
            {
                return push_result(lua, false, "WEDNativeSpawn packed path is not ASCII");
            }
            class_path_utf8[index] = static_cast<char>(character);
        }
        const std::size_t last_chunk_bytes = path_length % kPathChunkBytes;
        if (last_chunk_bytes != 0
            && (path_chunks.back() >> (8 * last_chunk_bytes)) != 0)
        {
            return push_result(lua, false, "WEDNativeSpawn packed path contains trailing data");
        }
        if (!class_path_utf8.starts_with("/Game/")
            || class_path_utf8.find('.') == std::string::npos)
        {
            return push_result(lua, false, "WEDNativeSpawn class path is not canonical");
        }
        if (level_value < 1 || level_value > std::numeric_limits<std::int32_t>::max())
        {
            return push_result(lua, false, "WEDNativeSpawn level is outside int32 range");
        }

        auto* game_state = reinterpret_cast<void*>(static_cast<std::uintptr_t>(game_state_address));
        void* function = g_api.get_function_by_name_in_chain(game_state, L"RODSpawnActor");
        if (function == nullptr)
        {
            return push_result(lua, false, "ARODGameState does not expose RODSpawnActor");
        }
        std::wstring class_path;
        class_path.reserve(class_path_utf8.size());
        for (const unsigned char character : class_path_utf8)
        {
            if (character == 0 || character > 0x7f)
            {
                return push_result(lua, false, "WEDNativeSpawn class path is not ASCII");
            }
            class_path.push_back(static_cast<wchar_t>(character));
        }
        void* actor_class = g_api.find_object(
            nullptr, nullptr, class_path.c_str(), false, nullptr);
        if (actor_class == nullptr)
        {
            return push_result(lua, false, "UObjectGlobals::FindObject could not resolve the loaded class");
        }

        const std::uint16_t* parms_size_ref = g_api.get_parms_size(function);
        if (parms_size_ref == nullptr || *parms_size_ref == 0)
        {
            return push_result(lua, false, "RODSpawnActor reported an invalid parameter size");
        }
        const int parms_size = *parms_size_ref;
        const int structure_size = g_api.get_structure_size(function);
        if (structure_size < parms_size)
        {
            return push_result(lua, false, "RODSpawnActor structure is smaller than its parameters");
        }

        PropertyList properties;
        std::string contract_error;
        if (!read_function_contract(function, parms_size, properties, contract_error))
        {
            return push_result(lua, false, contract_error);
        }

        PropertyView class_property;
        PropertyView transform_property;
        PropertyView option_property;
        PropertyView owner_property;
        PropertyView instigator_property;
        PropertyView collision_property;
        PropertyView return_property;
        if (!require_property(properties, 0, 0x8, false, class_property, contract_error)
            || !require_property(properties, 1, kTransformSize, false, transform_property, contract_error)
            || !require_property(properties, 2, kSpawnOptionSize, false, option_property, contract_error)
            || !require_property(properties, 3, 0x8, false, owner_property, contract_error)
            || !require_property(properties, 4, 0x8, false, instigator_property, contract_error)
            || !require_property(properties, 5, 0x1, false, collision_property, contract_error)
            || !require_property(properties, 6, kSpawnResultSize, true, return_property, contract_error))
        {
            return push_result(lua, false, contract_error);
        }

        void* params = _aligned_malloc(static_cast<std::size_t>(parms_size), 16);
        if (params == nullptr)
        {
            return push_result(lua, false, "native parameter allocation failed");
        }
        std::memset(params, 0, static_cast<std::size_t>(parms_size));
        g_api.initialize_struct(function, params, 1);

        bool initialized = true;
        auto cleanup = [&]() {
            if (initialized) g_api.destroy_struct(function, params, 1);
            _aligned_free(params);
        };

        g_api.set_object_property_value(
            class_property.property,
            static_cast<std::byte*>(params) + class_property.offset,
            actor_class);
        g_api.set_object_property_value(
            owner_property.property,
            static_cast<std::byte*>(params) + owner_property.offset,
            nullptr);
        g_api.set_object_property_value(
            instigator_property.property,
            static_cast<std::byte*>(params) + instigator_property.offset,
            nullptr);

        if (!import_exact(transform_property, params, game_state, transform_text(x, y, z), contract_error)
            || !import_exact(
                option_property,
                params,
                game_state,
                option_text(x, y, z, static_cast<std::int32_t>(level_value)),
                contract_error)
            || !import_exact(
                collision_property,
                params,
                game_state,
                L"AdjustIfPossibleButDontSpawnIfColliding",
                contract_error))
        {
            cleanup();
            return push_result(lua, false, contract_error);
        }

        if (!guarded_process_event(game_state, function, params))
        {
            cleanup();
            return push_result(lua, false, "RODSpawnActor raised a native exception");
        }

        const auto* result = reinterpret_cast<const SpawnResult*>(
            static_cast<const std::byte*>(params) + return_property.offset);
        const WeakObjectPtr weak = result->server_spawn_actor;
        void* actor = g_api.get_weak_object(&weak);
        const std::uint8_t spawn_on = result->spawn_on;
        cleanup();

        if (spawn_on != 0)
        {
            return push_result(lua, false, "RODSpawnActor returned a non-server spawn result");
        }
        if (actor == nullptr || weak.object_index < 0 || weak.object_serial_number <= 0)
        {
            return push_result(lua, false, "RODSpawnActor returned no valid server actor");
        }

        return push_result(
            lua,
            true,
            "RODSpawnActor accepted the request",
            static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(actor)),
            weak.object_index,
            weak.object_serial_number);
    }

    class WorldEnemyDirectorNative final : public RC::CppUserModBase
    {
      public:
        WorldEnemyDirectorNative()
        {
            ModName = L"WorldEnemyDirectorNative";
            ModVersion = L"1.8.1";
            ModDescription = L"Native reflected bridge for ARODGameState::RODSpawnActor";
            ModAuthors = L"WorldEnemyDirector";
            ModIntendedSDKVersion = L"3.0.1";
            g_api.load();
        }

        void on_lua_start(Lua& lua, Lua& main_lua, Lua& async_lua, Lua* hook_lua) override
        {
            if (!g_api.lua_ready()) return;

            const LuaFunction spawn = &native_spawn;
            const std::string spawn_name = "WEDNativeSpawn";

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
                g_api.register_function(states[index], spawn_name, spawn);
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
