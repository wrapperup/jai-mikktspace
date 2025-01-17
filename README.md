# Jai MikkTSpace

Port of [Morten S. Mikkelsen's Tangent Space algorithm](https://github.com/mmikk/MikkTSpace) in Jai.

## Usage

```odin
Mikk :: #import "jai-mikktspace";

mesh_data := ...

interface := Mikk.MikkInterface.{
    get_num_faces            = get_num_faces,
    get_num_vertices_of_face = get_num_vertices_of_face,
    get_position             = get_position,
    get_normal               = get_normal,
    get_tex_coord            = get_tex_coord,
    set_t_space_basic        = set_t_space_basic,
}

ctx := Mikk.MikkContext.{
    mikk_interface = *interface,
    user_data      = *mesh_data,
};

ok := Mikk.generate_tangents(*ctx);
```

[Full example can be found here](example/example.jai)

## License
[zlib License](LICENSE)
