extends SceneTree
const VertexShader = preload("res://legacy_vertex_lighting.gdshader")
func _initialize():
 call_deferred("verify")
func verify():
 var viewport=SubViewport.new()
 viewport.size=Vector2i(128,128)
 viewport.own_world_3d=true
 viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
 root.add_child(viewport)
 var camera=Camera3D.new()
 camera.position=Vector3(0,0,3)
 viewport.add_child(camera)
 camera.current=true
 var quad=MeshInstance3D.new()
 var mesh=QuadMesh.new()
 mesh.size=Vector2(2,2)
 quad.mesh=mesh
 var material=ShaderMaterial.new()
 material.shader=VertexShader
 material.set_shader_parameter("lighting_enabled",false)
 material.set_shader_parameter("material_diffuse",Vector4(.25,.25,.25,1))
 quad.material_override=material
 viewport.add_child(quad)
 await process_frame
 await RenderingServer.frame_post_draw
 var unlit:Color=viewport.get_texture().get_image().get_pixel(64,64)
 assert(absf(unlit.r-.25)<.008)
 # Phase 4c (Forward+): dark raw values survive the output encode too. The
 # Compatibility renderer's approximate sRGB round trip turned 10/255 into ~4/255.
 material.set_shader_parameter("material_diffuse",Vector4(10.0/255.0,29.0/255.0,.04,1))
 await process_frame
 await RenderingServer.frame_post_draw
 var dark:Color=viewport.get_texture().get_image().get_pixel(64,64)
 assert(absf(dark.r*255.0-10.0)<1.01 and absf(dark.g*255.0-29.0)<1.01 and absf(dark.b-.04)<.005)
 material.set_shader_parameter("lighting_enabled",true)
 material.set_shader_parameter("material_diffuse",Vector4(.2,.4,.6,1))
 material.set_shader_parameter("material_ambient",Vector3(.2,.4,.6))
 material.set_shader_parameter("light_position",Vector4(0,0,100,1))
 material.set_shader_parameter("material_specular",Vector3.ZERO)
 await process_frame
 await RenderingServer.frame_post_draw
 var diffuse:Color=viewport.get_texture().get_image().get_pixel(64,64)
 assert(absf(diffuse.r-.35)<.008 and absf(diffuse.g-.7)<.008 and diffuse.b>.99)
 material.set_shader_parameter("material_specular",Vector3.ONE)
 await process_frame
 await RenderingServer.frame_post_draw
 var highlight:Color=viewport.get_texture().get_image().get_pixel(64,64)
 assert(highlight.r>.99 and highlight.g>.99 and highlight.b>.99)
 var tex_image=Image.create(1,1,false,Image.FORMAT_RGB8)
 tex_image.fill(Color(.25,.5,.75))
 material.set_shader_parameter("scene_texture",ImageTexture.create_from_image(tex_image))
 material.set_shader_parameter("has_texture",true)
 await process_frame
 await RenderingServer.frame_post_draw
 var modulated:Color=viewport.get_texture().get_image().get_pixel(64,64)
 assert(absf(modulated.r-.25)<.008 and absf(modulated.g-.5)<.008 and absf(modulated.b-.75)<.008)
 material.set_shader_parameter("has_texture",false)
 material.set_shader_parameter("material_ambient",Vector3.ZERO) # Vertex routing must override this.
 material.set_shader_parameter("light_position",Vector4(0,0,-1,0))
 await process_frame
 await RenderingServer.frame_post_draw
 var backlit:Color=viewport.get_texture().get_image().get_pixel(64,64)
 assert(absf(backlit.r-.15)<.012 and absf(backlit.g-.3)<.012 and absf(backlit.b-.45)<.012)
 material.set_shader_parameter("light_position",Vector4(0,0,1,0))
 material.set_shader_parameter("material_diffuse",Vector4(0,0,0,1))
 material.set_shader_parameter("material_ambient",Vector3.ZERO)
 quad.rotation.y=.3
 await process_frame
 await RenderingServer.frame_post_draw
 var exponent:Color=viewport.get_texture().get_image().get_pixel(64,64)
 assert(absf(exponent.r-pow(cos(.3),38))<.008)
 print("PASS (",RenderingServer.get_current_rendering_method(),"): actual GPU raw RGB incl. dark ",dark,", original ambient+diffuse, white exponent specular, vertex clamp before texture modulation, backlight exclusion, exponent38; samples ",unlit," ",diffuse," ",highlight," ",modulated," ",backlit," ",exponent)
 viewport.queue_free()
 quit()
