#tool
extends VoxelGeneratorScript

const Structure = preload("./structure.gd")
const TreeGenerator = preload("./tree_generator.gd")
const HeightmapCurve = preload("./heightmap_curve.tres")

# TODO Don't hardcode, get by name from library somehow
const AIR = 0
const DIRT = 1
const GRASS = 2
const WATER_FULL = 14
const WATER_TOP = 13
const LOG = 4
const LEAVES = 25
const TALL_GRASS = 8
const DEAD_SHRUB = 26
#const STONE = 8

#VoxelStream
# CHANNEL_TYPE是什么神起名，看到这个名字我完全联想不到他是干什么的
const _CHANNEL = VoxelBuffer.CHANNEL_TYPE

const _moore_dirs = [
	Vector3(-1, 0, -1),
	Vector3(0, 0, -1),
	Vector3(1, 0, -1),
	Vector3(-1, 0, 0),
	Vector3(1, 0, 0),
	Vector3(-1, 0, 1),
	Vector3(0, 0, 1),
	Vector3(1, 0, 1)
]

# 用这个数组保存树的各种形态。
# 使得每次生成树时不需要重新计算
var _tree_structures := []

# 高度图的最高点和最低点，用于判断树是否能够放下
var _heightmap_min_y := int(HeightmapCurve.min_value)
var _heightmap_max_y := int(HeightmapCurve.max_value)
var _heightmap_range := 0
# 使用高度图噪声通过x，z求取高度，通过高度判断该树是否能够放下
var _heightmap_noise := OpenSimplexNoise.new()
# 这是对树是否能放下判断的一种优化方法
var _trees_min_y := 0
var _trees_max_y := 0


func _init():
	# TODO Even this must be based on a seed, but I'm lazy
	var tree_generator = TreeGenerator.new()
	tree_generator.log_type = LOG
	tree_generator.leaves_type = LEAVES
	# 生成16颗不同形态的树放入数组中
	for i in 16:
		var s = tree_generator.generate()
		_tree_structures.append(s)

	# 算出树最高能到达多少，最低能到多少
	var tallest_tree_height = 0
	for structure in _tree_structures:
		var h = int(structure.voxels.get_size().y)
		if tallest_tree_height < h:
			tallest_tree_height = h
	_trees_min_y = _heightmap_min_y
	_trees_max_y = _heightmap_max_y + tallest_tree_height

	# 这里的初始化缺少种子信息
	_heightmap_noise.period = 128
	_heightmap_noise.octaves = 4


func _get_used_channels_mask() -> int:
	return 1 << _CHANNEL


func _generate_block(buffer: VoxelBuffer, origin_in_voxels: Vector3, lod: int):
	# Assuming input is cubic in our use case (it doesn't have to be!)
	var block_size := int(buffer.get_size().x)
	var oy := int(origin_in_voxels.y)
	# TODO This hardcodes a cubic block size of 16, find a non-ugly way...
	# Dividing is a false friend because of negative values
	# 通过给定的坐标，求出该坐标所在的chunk的位置，该生成器是通过chunk将地图划分成块，每个chunk大小为16*16*16
	var chunk_pos := Vector3(
		int(origin_in_voxels.x) >> 4,
		int(origin_in_voxels.y) >> 4,
		int(origin_in_voxels.z) >> 4)

	_heightmap_range = _heightmap_max_y - _heightmap_min_y

	# Ground
	# 如果所在区块高于高度图最高点，直接生成空气填充
	if origin_in_voxels.y > _heightmap_max_y:
		buffer.fill(AIR, _CHANNEL)
	# 若所在区块低于高度图最低点，直接使用泥土方块填充，这里可以另起一个类，做地下洞穴，和其他方块资源
	elif origin_in_voxels.y + block_size < _heightmap_min_y:
		buffer.fill(DIRT, _CHANNEL)

	else:
		# 创建随机生成器
		var rng := RandomNumberGenerator.new()
		rng.seed = _get_chunk_seed_2d(chunk_pos)
		
		var gx : int
		var gz := int(origin_in_voxels.z)

		for z in block_size:
			gx = int(origin_in_voxels.x)

			for x in block_size:
				# 从高度图获取x，z点的高度
				var height := _get_height_at(gx, gz)
				var relative_height := height - oy
				
				# Dirt and grass
				if relative_height > block_size:
					buffer.fill_area(DIRT,
						Vector3(x, 0, z), Vector3(x + 1, block_size, z + 1), _CHANNEL)
				elif relative_height > 0:
					buffer.fill_area(DIRT,
						Vector3(x, 0, z), Vector3(x + 1, relative_height, z + 1), _CHANNEL)
					if height >= 0:
						buffer.set_voxel(GRASS, x, relative_height - 1, z, _CHANNEL)
						if relative_height < block_size and rng.randf() < 0.2:
							var foliage = TALL_GRASS
							if rng.randf() < 0.1:
								foliage = DEAD_SHRUB
							buffer.set_voxel(foliage, x, relative_height, z, _CHANNEL)
				
				# Water
				if height < 0 and oy < 0:
					var start_relative_height := 0
					if relative_height > 0:
						start_relative_height = relative_height
					buffer.fill_area(WATER_FULL,
						Vector3(x, start_relative_height, z), 
						Vector3(x + 1, block_size, z + 1), _CHANNEL)
					if oy + block_size == 0:
						# Surface block
						buffer.set_voxel(WATER_TOP, x, block_size - 1, z, _CHANNEL)
						
				gx += 1

			gz += 1

	# Trees

	if origin_in_voxels.y <= _trees_max_y and origin_in_voxels.y + block_size >= _trees_min_y:
		var voxel_tool := buffer.get_voxel_tool()
		var structure_instances := []
			
		_get_tree_instances_in_chunk(chunk_pos, origin_in_voxels, block_size, structure_instances)
	
		# Relative to current block
		var block_aabb := AABB(Vector3(), buffer.get_size() + Vector3(1, 1, 1))

		for dir in _moore_dirs:
			var ncpos : Vector3 = (chunk_pos + dir).round()
			_get_tree_instances_in_chunk(ncpos, origin_in_voxels, block_size, structure_instances)

		for structure_instance in structure_instances:
			var pos : Vector3 = structure_instance[0]
			var structure : Structure = structure_instance[1]
			var lower_corner_pos := pos - structure.offset
			var aabb := AABB(lower_corner_pos, structure.voxels.get_size() + Vector3(1, 1, 1))

			if aabb.intersects(block_aabb):
				# paste 粘贴，将structure.voxels buffer 粘贴至 lower_corner_pos 位置处，voxels buffer中空白字段，用掩码 AIR 填充
				voxel_tool.paste(lower_corner_pos, structure.voxels, AIR)

	buffer.optimize()


func _get_tree_instances_in_chunk(
	cpos: Vector3, offset: Vector3, chunk_size: int, tree_instances: Array):
		
	var rng := RandomNumberGenerator.new()
	rng.seed = _get_chunk_seed_2d(cpos)

	for i in 4:
		var pos := Vector3(rng.randi() % chunk_size, 0, rng.randi() % chunk_size)
		pos += cpos * chunk_size
		pos.y = _get_height_at(pos.x, pos.z)
		
		if pos.y > 0:
			pos -= offset
			var si := rng.randi() % len(_tree_structures)
			var structure : Structure = _tree_structures[si]
			tree_instances.append([pos.round(), structure])


#static func get_chunk_seed(cpos: Vector3) -> int:
#	return cpos.x ^ (13 * int(cpos.y)) ^ (31 * int(cpos.z))

# 这里因为没有传入种子，所以使用自己生成的种子
static func _get_chunk_seed_2d(cpos: Vector3) -> int:
	return int(cpos.x) ^ (31 * int(cpos.z))


func _get_height_at(x: int, z: int) -> int:
	var t = 0.5 + 0.5 * _heightmap_noise.get_noise_2d(x, z)
	return int(HeightmapCurve.interpolate_baked(t))
