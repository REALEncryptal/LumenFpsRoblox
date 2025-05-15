local TweenService = game:GetService("TweenService")
--[[

    WeaponUI
        A controller for the weapon UI
    
    Created Saturday, May 10th 2025, 1:47:19 pm
    RealEncryptal
    
--]]

local WeaponUI = {
    _Raw = true -- this is not a controller, DO NOT INIT
}

local Controller, TweenUtil

function WeaponUI:Init(InterfaceController)
    Controller = InterfaceController
    TweenUtil = shared.Import("TweenUtil")

    WeaponUI.ToolObject = nil
    WeaponUI.Instance = Controller.Instance:WaitForChild("LoadoutInfo")

    WeaponUI.Show = TweenUtil.CreateTransparencyTween(
        WeaponUI.Instance,
        nil,
        .2
    )
    WeaponUI.Hide = TweenUtil.CreateTransparencyTween(
        WeaponUI.Instance,
        1,
        .2
    )
    
    return WeaponUI
end

function WeaponUI:WatchTool(ToolObject: any?)
    if not ToolObject then
        WeaponUI.ToolObject = nil
        WeaponUI:SetIcon("")
        WeaponUI:SetAmmo("", "")
        return
    end
    
    WeaponUI.ToolObject = ToolObject
    WeaponUI:SetIcon(ToolObject.Data.HudImage)

    if ToolObject.Type ~= "Firearm" then return end

    if ToolObject.State.Reloading then
        WeaponUI:SetAmmo("--", ToolObject.State.StoredAmmo)
    else
        WeaponUI:SetAmmo(ToolObject.State.Ammo, ToolObject.State.StoredAmmo)
    end
end

function WeaponUI:SetIcon(ImageId:string?)
    Controller:SetImage(WeaponUI.Instance.ToolImage, ImageId) 
end

function WeaponUI:SetAmmo(Ammo: (number|string)?, StoredAmmo: (number|string)?)
    if Ammo then
        if typeof(Ammo) == "number" then
            Ammo = Ammo > 0 and Ammo or "--"
        end
        Controller:SetText(WeaponUI.Instance.AmmoInfo.AmmoLabel, tostring(Ammo))
    end
    
    if StoredAmmo then
        if typeof(StoredAmmo) == "number" then
            StoredAmmo = StoredAmmo > 0 and StoredAmmo or "--"
        end
        Controller:SetText(WeaponUI.Instance.AmmoInfo.StoredAmmoLabel, tostring(StoredAmmo))
    end
end

function WeaponUI:Update(DeltaTime: number) 
    WeaponUI:WatchTool(WeaponUI.ToolObject)
end

return WeaponUI