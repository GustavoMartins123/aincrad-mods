-- GNatives.lua - Echoes of Aincrad RETAIL (EchoesofAincrad-Win64-Shipping.exe)
-- Self-built 2026-07-11 (static disasm of .text1; the exe is protected, but .text1
-- is unencrypted so the pattern matches at runtime too).
-- GNatives @ 0x148184980 (image_base 0x140000000).
-- Anchor = the UObject bytecode-VM dispatch site (unique across the whole image):
--   lea r9,[GNatives] ; mov eax,ecx ; mov rdx,rbx ; mov rcx,[rbx+0x18] ; call [r9+rax*8]
--
-- DEPLOY: copy into  ...\EchoesofAincrad\Binaries\Win64\ue4ss\UE4SS_Signatures\
-- next to eluwave's GUObjectArray.lua. Fixes "GNatives not found" on the retail build.
-- If a game update changes the exe, re-run scratchpad find_gnatives.py + finalize_sig.py.
function Register()
    return "4C 8D 0D ?? ?? ?? ?? 8B C1 48 8B D3 48 8B 4B 18 41 FF 14 C1"
end

function OnMatchFound(MatchAddress)
    -- match starts at 'lea r9, [rip + disp32]'  (4C 8D 0D <disp32>, 7 bytes long)
    local disp = DerefToInt32(MatchAddress + 0x03)
    return MatchAddress + 0x07 + disp
end

-- GNatives by Sp1axx - https://www.nexusmods.com/profile/Sp1axx