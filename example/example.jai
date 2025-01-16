cube_indices: [36]u32 = .[
	2,  5,  11, 2, 
	11, 8,  6,  9,
	21, 6,  21, 18,
	20, 23, 17, 20,
	17, 14, 12, 15,
	3,  12, 3,  0,
	7,  19, 13, 7,
	13, 1,  22, 10, 
	4,  22, 4,  1,
];

cube_positions: [24]Vector3 = .[
	.{-1, -1,  1}, .{-1, -1,  1}, .{-1, -1,  1}, .{-1,  1,  1},
	.{-1,  1,  1}, .{-1,  1,  1}, .{-1, -1, -1}, .{-1, -1, -1},
	.{-1, -1, -1}, .{-1,  1, -1}, .{-1,  1, -1}, .{-1,  1, -1},
	.{ 1, -1,  1}, .{ 1, -1,  1}, .{ 1, -1,  1}, .{ 1,  1,  1},
	.{ 1,  1,  1}, .{ 1,  1,  1}, .{ 1, -1, -1}, .{ 1, -1, -1},
	.{ 1, -1, -1}, .{ 1,  1, -1}, .{ 1,  1, -1}, .{ 1,  1, -1},
];

cube_normals: [24]Vector3 = .[
	.{ 0,  0,  1}, .{ 0, -1,  0}, .{-1,  0,  0}, .{ 0,  0,  1},
 	.{ 0,  1,  0}, .{-1,  0,  0}, .{ 0,  0, -1}, .{ 0, -1,  0},
 	.{-1,  0,  0}, .{ 0,  0, -1}, .{ 0,  1,  0}, .{-1,  0,  0},
 	.{ 0,  0,  1}, .{ 0, -1,  0}, .{ 1,  0,  0}, .{ 0,  0,  1},
 	.{ 0,  1,  0}, .{ 1,  0,  0}, .{ 0,  0, -1}, .{ 0, -1,  0},
 	.{ 1,  0,  0}, .{ 0,  0, -1}, .{ 0,  1,  0}, .{ 1,  0,  0},
];

cube_uvs: [24]Vector2 = .[
	.{ 0, 1 }, .{ 0, 1 }, .{ 0, 1 }, .{ 0, 0 },
 	.{ 0, 1 }, .{ 0, 0 }, .{ 0, 1 }, .{ 0, 0 },
 	.{ 1, 1 }, .{ 0, 0 }, .{ 0, 0 }, .{ 1, 0 },
 	.{ 1, 1 }, .{ 1, 1 }, .{ 0, 1 }, .{ 1, 0 },
 	.{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 0 },
 	.{ 1, 1 }, .{ 1, 0 }, .{ 1, 0 }, .{ 1, 0 },
];

cube_check_tangents: [24]Vector4 = .[
	.{-1, 0, 0, -1}, .{ 1, 0, 0, -1}, .{ 0, 0, 1,  1}, .{-1, 0, 0, -1},
 	.{-1, 0, 0, -1}, .{ 0, 0, 1,  1}, .{-1, 0, 0,  1}, .{-1, 0, 0,  1},
 	.{ 0, 0, 1,  1}, .{-1, 0, 0,  1}, .{-1, 0, 0, -1}, .{ 0, 0, 1,  1},
 	.{-1, 0, 0, -1}, .{-1, 0, 0,  1}, .{ 0, 0, 1, -1}, .{-1, 0, 0, -1},
 	.{ 0, 0, 0,  0}, .{ 0, 0, 1, -1}, .{-1, 0, 0,  1}, .{-1, 0, 0,  1},
 	.{ 0, 0, 1, -1}, .{-1, 0, 0,  1}, .{-1, 0, 0, -1}, .{ 0, 0, 1, -1},
];

Mesh :: struct {
	indices:   [] u32;
	positions: [] Vector3;
	normals:   [] Vector3;
	uvs:       [] Vector2;
	tangents:  [] Vector4;
}

get_vertex_index :: (pContext: *Mikk.MikkContext, iFace: int, iVert: int) -> int {
	mesh := cast(*Mesh)pContext.user_data;

	indices_index := iVert + (iFace * get_num_vertices_of_face(pContext, iFace));
	index := mesh.indices[indices_index];

	return xx index;
}

get_num_faces :: (pContext: *Mikk.MikkContext) -> int {
	mesh := cast(*Mesh) pContext.user_data;
	return mesh.indices.count / 3;
}

get_num_vertices_of_face :: (pContext: *Mikk.MikkContext, iFace: int) -> int {
	return 3; // Triangles have 3 vertices.
}

get_position :: (pContext: *Mikk.MikkContext, iFace: int, iVert: int) -> Vector3 {
	mesh := cast(*Mesh) pContext.user_data;
	return mesh.positions[get_vertex_index(pContext, iFace, iVert)];
}

get_normal :: (pContext: *Mikk.MikkContext, iFace: int, iVert: int) -> Vector3 {
	mesh := cast(*Mesh) pContext.user_data;
	return mesh.normals[get_vertex_index(pContext, iFace, iVert)];
}

get_tex_coord :: (pContext: *Mikk.MikkContext, iFace: int, iVert: int) -> Vector2 {
	mesh := cast(*Mesh) pContext.user_data;
	return mesh.uvs[get_vertex_index(pContext, iFace, iVert)];
}

set_t_space_basic :: (pContext: *Mikk.MikkContext, fvTangent: Vector3, fSign: float32, iFace: int, iVert: int) {
	mesh := cast(*Mesh) pContext.user_data;
	index := get_vertex_index(pContext, iFace, iVert);

	mesh.tangents[index].xyz = fvTangent;
	mesh.tangents[index].w = fSign;
}

main :: () {
	gen_tangents: [24]Vector4;

	mesh_data := Mesh.{
		indices   = cube_indices,
		positions = cube_positions,
		normals   = cube_normals,
		uvs       = cube_uvs,
		tangents  = gen_tangents,
	};

	mikk_interface := Mikk.MikkInterface.{
		get_num_faces            = get_num_faces,
		get_num_vertices_of_face = get_num_vertices_of_face,
		get_position             = get_position,
		get_normal               = get_normal,
		get_tex_coord            = get_tex_coord,
		set_t_space_basic        = set_t_space_basic,
		//set_t_space	          = set_t_space, // for more uses beyond basic normal-mapping.
	};

	ctx := Mikk.MikkContext.{
		mikk_interface = *mikk_interface,
		user_data = *mesh_data,
	};

	ok := Mikk.generate_tangents(*ctx);
	assert(ok, "Could not generate tangents.");

	for i: 0 .. gen_tangents.count-1 {
		assert(gen_tangents[i] == cube_check_tangents[i]);
	}

	print("Tangents generated!\n");
	print("%\n", gen_tangents);

	report_memory_leaks;
}

#import "Basic"()(MEMORY_DEBUGGER=true);
#import "Math";

Mikk :: #import,file "../module.jai";
