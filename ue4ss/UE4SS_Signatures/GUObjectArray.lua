function Register()
    return "8B 3D ?? ?? ?? ?? FF C7 8B CF"
end

function OnMatchFound(MatchAddress)
    local InstrSize = 0x06 
    
    local Offset = DerefToInt32(MatchAddress + 0x02)
    
    local ObjLastNonGCIndex = MatchAddress + InstrSize + Offset
    
    local GUObjectArray = ObjLastNonGCIndex - 0x04
    
    return GUObjectArray
end