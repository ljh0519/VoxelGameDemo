class_name TreeGenerator

class TreeBuffer:
	var offset := Vector3()
	var voxels := VoxelBuffer.new()







# 树干的高度
var trunk_len_min : int = 6
var trunk_len_max : int = 12
var log_x_id : int 
var log_y_id : int 
var log_z_id : int 
var leaves_id : int
var channel : int = VoxelBuffer.CHANNEL_TYPE

var blocksPerGrow : int


# 生成不同形态的树
func generate() -> TreeBuffer:
	return TreeBuffer.new()



func grow() -> void:
	pass
