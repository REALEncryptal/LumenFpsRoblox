local Objects = {}

for _, Object in ipairs(script:GetChildren()) do
    Objects[Object.Name] = require(Object)
end

return Objects