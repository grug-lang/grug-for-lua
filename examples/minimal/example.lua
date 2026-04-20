package.path = package.path .. ";../../?.lua"
grug = require("grug")

state = grug.init()

state:register_game_fn("print_string", function(state, string)
	print(string)
end)

file = state:compile_grug_file("animals/labrador-Dog.grug")
dog1 = file:create_entity()
dog2 = file:create_entity()

dog1:on_bark("woof")
dog2:on_bark("arf")
