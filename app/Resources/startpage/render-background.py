# 브라우저 시작 페이지의 다크 모드 배경 (background-dark.jpg = 변형 c, 2026-11-19) — 겹친 천 면을 Blender(Cycles)로 그린다. 사진·소재를 쓰지 않는다.
# 다시 그리기: blender -b -P render-background.py -- out.png 2880 1800 192 c -1.5
#             sips -s format jpeg -s formatOptions 82 -Z 2560 out.png --out background-dark.jpg
# 인자: <out.png> <폭> <높이> <샘플> <변형 a~e> <노출>
import bpy, math, sys
argv = sys.argv[sys.argv.index("--")+1:]
out, RW, RH, SAMPLES, VAR = argv[0], int(argv[1]), int(argv[2]), int(argv[3]), argv[4] if len(argv) > 4 else "a"

bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = 'CYCLES'
sc.cycles.device = 'GPU'
prefs = bpy.context.preferences.addons['cycles'].preferences
prefs.compute_device_type = 'METAL'; prefs.get_devices()
for d in prefs.devices: d.use = True
sc.cycles.samples = SAMPLES; sc.cycles.use_denoising = True
sc.render.resolution_x, sc.render.resolution_y = RW, RH
sc.render.film_transparent = False
sc.view_settings.view_transform = 'AgX'; sc.view_settings.look = 'AgX - Medium High Contrast'
sc.view_settings.exposure = float(argv[5]) if len(argv) > 5 else -2.0

# 세계: 아주 어두운 남색
w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.002, 0.002, 0.006, 1)
w.node_tree.nodes["Background"].inputs[1].default_value = 1.0

def mat(name, col, rough=0.38, sheen=0.4):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*col, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Sheen Weight"].default_value = sheen
    b.inputs["Sheen Tint"].default_value = (0.75, 0.75, 1.0, 1)
    b.inputs["Coat Weight"].default_value = 0.25
    b.inputs["Coat Roughness"].default_value = 0.25
    return m

# 면 하나: u(가로 0..1) · v(세로 0..1) 격자. 가장자리 곡선은 세로 S, 오른쪽 끝은 앞으로 말려 빛을 받는다
TILT = 0.32
FOLD = 0.22
def sheet(name, x0, width, depth, amp, phase, curl, m, nu=90, nv=160):
    verts, faces = [], []
    for j in range(nv+1):
        v = j/nv; y = -2.6 + v*5.2
        s = amp*math.sin(2*math.pi*(v*1.15 + phase)) + 0.35*amp*math.sin(2*math.pi*(v*2.1 + phase*1.7))
        for i in range(nu+1):
            u = i/nu
            x = x0 + s - (1-u)*width          # 오른쪽 가장자리가 x0+s, 왼쪽으로 넓게
            z = depth + TILT*u + curl*(u**4) + FOLD*math.sin(2*math.pi*(v*0.9 + phase*1.3))*(0.3+0.7*u)  # 오른쪽으로 갈수록 앞으로 — 빛을 향해 기울어 그늘→밝음
            verts.append((x, y, z))
    for j in range(nv):
        for i in range(nu):
            a = j*(nu+1)+i; faces.append((a, a+1, a+nu+2, a+nu+1))
    me = bpy.data.meshes.new(name); me.from_pydata(verts, [], faces); me.update()
    for p in me.polygons: p.use_smooth = True
    ob = bpy.data.objects.new(name, me); sc.collection.objects.link(ob)
    sol = ob.modifiers.new("t", 'SOLIDIFY'); sol.thickness = 0.035
    bv = ob.modifiers.new("b", 'BEVEL'); bv.width = 0.016; bv.segments = 4; bv.limit_method = 'ANGLE'
    ob.modifiers.new("s", 'SUBSURF').levels = 1
    ob.modifiers.new("w", 'WEIGHTED_NORMAL')
    ob.data.materials.append(m)
    return ob

V = {
 "c": [(-1.15, 3.6, 0.00, 0.42, 0.05, 0.14, (0.026, 0.028, 0.080)),
       (-0.35, 3.6, 0.24, 0.46, 0.22, 0.14, (0.032, 0.036, 0.100)),
       ( 0.45, 3.6, 0.48, 0.48, 0.40, 0.16, (0.040, 0.046, 0.125)),
       ( 1.25, 3.6, 0.72, 0.44, 0.58, 0.16, (0.050, 0.058, 0.150)),
       ( 2.05, 3.6, 0.96, 0.40, 0.76, 0.16, (0.060, 0.070, 0.170))],
 "d": [(-1.15, 3.6, 0.00, 0.42, 0.05, 0.14, (0.040, 0.026, 0.090)),
       (-0.35, 3.6, 0.24, 0.46, 0.22, 0.14, (0.050, 0.034, 0.112)),
       ( 0.45, 3.6, 0.48, 0.48, 0.40, 0.16, (0.062, 0.044, 0.138)),
       ( 1.25, 3.6, 0.72, 0.44, 0.58, 0.16, (0.074, 0.056, 0.160)),
       ( 2.05, 3.6, 0.96, 0.40, 0.76, 0.16, (0.086, 0.068, 0.180))],
 "e": [(-1.15, 3.6, 0.00, 0.42, 0.05, 0.14, (0.022, 0.026, 0.075)),
       (-0.35, 3.6, 0.24, 0.46, 0.22, 0.14, (0.030, 0.034, 0.098)),
       ( 0.45, 3.6, 0.48, 0.48, 0.40, 0.16, (0.044, 0.040, 0.125)),
       ( 1.25, 3.6, 0.72, 0.44, 0.58, 0.16, (0.060, 0.048, 0.150)),
       ( 2.05, 3.6, 0.96, 0.40, 0.76, 0.16, (0.078, 0.058, 0.172))],
 # (오른쪽 가장자리 x, 폭, 깊이, S 크기, 위상, 말림, 색)
 "a": [(-1.05, 3.5, 0.00, 0.20, 0.10, 0.12, (0.030, 0.030, 0.085)),
       (-0.30, 3.5, 0.22, 0.22, 0.32, 0.12, (0.036, 0.038, 0.105)),
       ( 0.45, 3.5, 0.44, 0.24, 0.55, 0.14, (0.045, 0.050, 0.130)),
       ( 1.20, 3.5, 0.66, 0.22, 0.78, 0.16, (0.060, 0.068, 0.160)),
       ( 1.95, 3.5, 0.88, 0.20, 0.98, 0.16, (0.072, 0.082, 0.180))],
 "b": [(-0.95, 3.6, 0.00, 0.26, 0.20, 0.14, (0.045, 0.030, 0.100)),
       ( 0.25, 3.6, 0.30, 0.28, 0.45, 0.16, (0.055, 0.040, 0.125)),
       ( 1.20, 3.6, 0.60, 0.26, 0.70, 0.18, (0.070, 0.055, 0.150)),
       ( 2.10, 3.6, 0.90, 0.24, 0.92, 0.18, (0.080, 0.068, 0.170))],
}[VAR]
# 왼쪽 면이 앞 — 오른쪽 가장자리(빛 테두리)가 뒤 면 위에 그림자를 드리운다
for k, (x0, wd, dp, amp, ph, cu, col) in enumerate(V):
    sheet(f"S{k}", x0, wd, V[len(V)-1-k][2], amp, ph, cu, mat(f"M{k}", col))

bpy.ops.mesh.primitive_plane_add(size=20, location=(0, 0, -0.9))
bpy.context.object.data.materials.append(mat("back", (0.020, 0.020, 0.055), rough=0.6, sheen=0.0))
# 빛: 오른쪽 위 넓은 면광 + 오른쪽 뒤 가장자리 빛 + 아주 약한 앞 채움
def area(name, loc, rot, size, energy, col):
    l = bpy.data.lights.new(name, 'AREA'); l.size = size; l.energy = energy; l.color = col
    o = bpy.data.objects.new(name, l); o.location = loc; o.rotation_euler = [math.radians(a) for a in rot]; sc.collection.objects.link(o)
area("key", (-2.6, 3.4, 3.6), (-40, -32, 0), 4.0, 300, (0.80, 0.80, 1.0))
area("rim", (3.2, 0.8, 0.4), (0, 95, 0), 1.0, 950, (0.86, 0.84, 1.0))
area("rim2", (0.6, 3.6, 0.6), (-95, 0, 0), 1.0, 600, (0.80, 0.82, 1.0))
area("glow", (1.8, 1.6, 2.6), (-30, 35, 0), 3.0, 120, (0.6, 0.55, 1.0))
area("fill", (-1.5, -0.5, 3.5), (10, -25, 0), 5.0, 40, (0.55, 0.6, 1.0))

cam = bpy.data.cameras.new("C"); cam.lens = 50
co = bpy.data.objects.new("C", cam); co.location = (0.1, 0, 5.2); sc.collection.objects.link(co); sc.camera = co
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
