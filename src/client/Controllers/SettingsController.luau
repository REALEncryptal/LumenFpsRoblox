local Controller = {}

Controller.Priority = 10

function Controller:Init() 
    Controller._Settings = {
        FOV = 70,
    }
end

function Controller:GetSetting( SettingName: string ): any?
    return Controller._Settings[SettingName]
end

return Controller