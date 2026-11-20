const THREAD_COUNT = 16;
const PI = 3.1415927f;
const MAX_DIST = 1000.0;

@group(0) @binding(0)
  var<storage, read_write> fb : array<vec4f>;

@group(1) @binding(0)
  var<storage, read_write> uniforms : array<f32>;

@group(2) @binding(0)
  var<storage, read_write> shapesb : array<shape>;

@group(2) @binding(1)
  var<storage, read_write> shapesinfob : array<vec4f>;

struct shape {
  transform : vec4f, // xyz = position
  radius : vec4f, // xyz = scale, w = global scale
  rotation : vec4f, // xyz = rotation
  op : vec4f, // x = operation, y = k value, z = repeat mode, w = repeat offset
  color : vec4f, // xyz = color
  animate_transform : vec4f, // xyz = animate position value (sin amplitude), w = animate speed
  animate_rotation : vec4f, // xyz = animate rotation value (sin amplitude), w = animate speed
  quat : vec4f, // xyzw = quaternion
  transform_animated : vec4f, // xyz = position buffer
};

struct march_output {
  color : vec3f,
  depth : f32,
  outline : bool,
};

// smooth min/max from https://iquilezles.org/articles/smin/
// h goes from 0 to 1 inside the blend region and is also used to mix the colors
fn op_smooth_union(d1: f32, d2: f32, col1: vec3f, col2: vec3f, k: f32) -> vec4f
{
  var k_eps = max(k, 0.0001);
  var h = clamp(0.5 + 0.5 * (d2 - d1) / k_eps, 0.0, 1.0);
  var d = mix(d2, d1, h) - k_eps * h * (1.0 - h);
  var col = mix(col2, col1, h);
  return vec4f(col, d);
}

// removes d1 from d2
fn op_smooth_subtraction(d1: f32, d2: f32, col1: vec3f, col2: vec3f, k: f32) -> vec4f
{
  var k_eps = max(k, 0.0001);
  var h = clamp(0.5 - 0.5 * (d2 + d1) / k_eps, 0.0, 1.0);
  var d = mix(d2, -d1, h) + k_eps * h * (1.0 - h);
  var col = mix(col2, col1, h);
  return vec4f(col, d);
}

fn op_smooth_intersection(d1: f32, d2: f32, col1: vec3f, col2: vec3f, k: f32) -> vec4f
{
  var k_eps = max(k, 0.0001);
  var h = clamp(0.5 - 0.5 * (d2 - d1) / k_eps, 0.0, 1.0);
  var d = mix(d2, d1, h) + k_eps * h * (1.0 - h);

  // d1 is only a cutting volume, the visible surface keeps the color of d2
  return vec4f(col2, d);
}

fn op(op: f32, d1: f32, d2: f32, col1: vec3f, col2: vec3f, k: f32) -> vec4f
{
  // union
  if (op < 1.0)
  {
    return op_smooth_union(d1, d2, col1, col2, k);
  }

  // subtraction
  if (op < 2.0)
  {
    return op_smooth_subtraction(d2, d1, col2, col1, k);
  }

  // intersection
  return op_smooth_intersection(d2, d1, col2, col1, k);
}

// wraps space into cells of size "offset", centered on the object
fn repeat(p: vec3f, offset: vec3f) -> vec3f
{
  return modc(p + 0.5 * offset, offset) - 0.5 * offset;
}

fn transform_p(p: vec3f, option: vec2f) -> vec3f
{
  // normal mode
  if (option.x <= 1.0)
  {
    return p;
  }

  // return repeat / mod mode
  return repeat(p, vec3f(option.y));
}

fn shape_distance(p: vec3f, shape_type: f32, s: shape) -> f32
{
  if (shape_type < 1.0)
  {
    return sdf_sphere(p, s.radius, s.quat);
  }

  if (shape_type < 2.0)
  {
    return sdf_round_box(p, s.radius.xyz, s.radius.w, s.quat);
  }

  return sdf_torus(p, s.radius.xy, s.quat);
}

fn scene(p: vec3f) -> vec4f // xyz = color, w = distance
{
    var d = mix(100.0, p.y, uniforms[17]);

    var spheresCount = i32(uniforms[2]);
    var boxesCount = i32(uniforms[3]);
    var torusCount = i32(uniforms[4]);

    var all_objects_count = spheresCount + boxesCount + torusCount;
    var result = vec4f(vec3f(1.0), d);

    for (var i = 0; i < all_objects_count; i = i + 1)
    {
      // shapesinfo has the following format:
      // x: shape type (0: sphere, 1: box, 2: torus)
      // y: shape index
      // order matters for the operations, they're sorted on the CPU side
      var info = shapesinfob[i];
      var s = shapesb[i32(info.y)];

      // move the point instead of the object, then apply repetition if enabled
      var local_p = transform_p(p - s.transform_animated.xyz, s.op.zw);
      var dist = shape_distance(local_p, info.x, s);

      // op format:
      // x: operation (0: union, 1: subtraction, 2: intersection)
      // y: k value
      // z: repeat mode (0: normal, 2: repeat)
      // w: repeat offset
      result = op(s.op.x, result.w, dist, result.xyz, s.color.xyz, s.op.y);
    }

    // fractal scenes
    if (uniforms[18] > 0.5)
    {
      var bulb = sdf_mandelbulb(p - vec3f(0.0, 1.0, 0.0));
      var bulb_color = mix(vec3f(0.9, 0.35, 0.1), vec3f(0.2, 0.5, 1.0), clamp(bulb.y * 1.5, 0.0, 1.0));
      result = op_smooth_union(result.w, bulb.x, result.xyz, bulb_color, 0.0001);
    }

    if (uniforms[19] > 0.5)
    {
      var weird = sdf_weird_thing(p, 1.2 + 0.05 * sin(uniforms[0] * 0.5));
      var weird_color = mix(vec3f(0.9), 0.5 + 0.5 * cos(vec3f(0.0, 0.6, 1.2) + p.y * 2.0), 0.3);
      result = op_smooth_union(result.w, weird, result.xyz, weird_color, 0.0001);
    }

    if (uniforms[31] > 0.5)
    {
      var mp = p - vec3f(0.0, 1.0, 0.0);
      var spin = rot(uniforms[0] * 0.3);
      mp = vec3f(spin * mp.xz, mp.y).xzy;
      var sponge = sdf_menger(mp, 4);
      var sponge_color = mix(vec3f(0.95, 0.85, 0.6), vec3f(0.6, 0.2, 0.1), clamp(length(mp) - 0.8, 0.0, 1.0));
      result = op_smooth_union(result.w, sponge, result.xyz, sponge_color, 0.0001);
    }

    return result;
}

fn march(ro: vec3f, rd: vec3f) -> march_output
{
  var max_marching_steps = i32(uniforms[5]);
  var EPSILON = uniforms[23];

  var depth = 0.0;
  var color = vec3f(0.0);
  var march_step = uniforms[22];

  var hit = false;
  var closest = MAX_DIST;

  for (var i = 0; i < max_marching_steps; i = i + 1)
  {
      var res = scene(ro + rd * depth);

      // close enough to a surface: count it as a hit
      if (res.w < EPSILON)
      {
        color = res.xyz;
        hit = true;
        break;
      }

      // remember how close the ray got to something, used for the outline
      closest = min(closest, res.w);

      // the scene distance is how far we can safely move along the ray
      depth += res.w * march_step;

      if (depth > MAX_DIST)
      {
        break;
      }
  }

  if (!hit)
  {
    depth = MAX_DIST;
  }

  // rays that missed but passed right next to a surface are the silhouette
  var outline = !hit && closest < uniforms[27];
  return march_output(color, depth, outline);
}

// gradient of the distance field, using the tetrahedron trick (4 samples instead of 6)
// https://iquilezles.org/articles/normalsSDF/
fn get_normal(p: vec3f) -> vec3f
{
  var e = vec2f(1.0, -1.0) * 0.0005;
  return normalize(
    e.xyy * scene(p + e.xyy).w +
    e.yyx * scene(p + e.yyx).w +
    e.yxy * scene(p + e.yxy).w +
    e.xxx * scene(p + e.xxx).w
  );
}

// https://iquilezles.org/articles/rmshadows/
// march towards the light, the closer the ray passes to an object the darker the shadow
// small k gives hard shadows, bigger k gives softer ones
fn get_soft_shadow(ro: vec3f, rd: vec3f, tmin: f32, tmax: f32, k: f32) -> f32
{
  var res = 1.0;
  var t = tmin;

  for (var i = 0; i < 128; i = i + 1)
  {
    if (t > tmax)
    {
      break;
    }

    var h = scene(ro + rd * t).w;
    res = min(res, h / (max(k, 0.0001) * t));

    if (res < 0.001)
    {
      break;
    }

    t += clamp(h, 0.005, 0.5);
  }

  return clamp(res, 0.0, 1.0);
}

fn get_AO(current: vec3f, normal: vec3f) -> f32
{
  var occ = 0.0;
  var sca = 1.0;
  for (var i = 0; i < 5; i = i + 1)
  {
    var h = 0.001 + 0.15 * f32(i) / 4.0;
    var d = scene(current + h * normal).w;
    occ += (h - d) * sca;
    sca *= 0.95;
  }

  return clamp( 1.0 - 2.0 * occ, 0.0, 1.0 ) * (0.5 + 0.5 * normal.y);
}

fn get_ambient_light(light_pos: vec3f, sun_color: vec3f, rd: vec3f) -> vec3f
{
  var backgroundcolor1 = int_to_rgb(i32(uniforms[12]));
  var backgroundcolor2 = int_to_rgb(i32(uniforms[29]));
  var backgroundcolor3 = int_to_rgb(i32(uniforms[30]));

  var ambient = backgroundcolor1 - rd.y * rd.y * 0.5;
  ambient = mix(ambient, 0.85 * backgroundcolor2, pow(1.0 - max(rd.y, 0.0), 4.0));

  var sundot = clamp(dot(rd, normalize(vec3f(light_pos))), 0.0, 1.0);
  var sun = 0.25 * sun_color * pow(sundot, 5.0) + 0.25 * vec3f(1.0,0.8,0.6) * pow(sundot, 64.0) + 0.2 * vec3f(1.0,0.8,0.6) * pow(sundot, 512.0);
  ambient += sun;
  ambient = mix(ambient, 0.68 * backgroundcolor3, pow(1.0 - max(rd.y, 0.0), 16.0));

  return ambient;
}

fn get_light(current: vec3f, obj_color: vec3f, rd: vec3f) -> vec3f
{
  var light_position = vec3f(uniforms[13], uniforms[14], uniforms[15]);
  var sun_color = int_to_rgb(i32(uniforms[16]));
  var ambient = get_ambient_light(light_position, sun_color, rd);

  // if the object is too far away from the light source, return ambient light
  if (length(current) > uniforms[20] + uniforms[8])
  {
    return ambient;
  }

  var normal = get_normal(current);

  var light_dir = normalize(light_position - current);
  var diffuse = clamp(dot(normal, light_dir), 0.0, 1.0);

  // start the shadow ray a bit off the surface so it doesn't hit itself
  var shadow = get_soft_shadow(current + normal * 0.01, light_dir, uniforms[24], uniforms[25], uniforms[21]);
  var ao = get_AO(current, normal);

  var light = sun_color * diffuse * shadow + ambient * ao * 0.6;
  return obj_color * light;
}

fn set_camera(ro: vec3f, ta: vec3f, cr: f32) -> mat3x3<f32>
{
  var cw = normalize(ta - ro);
  var cp = vec3f(sin(cr), cos(cr), 0.0);
  var cu = normalize(cross(cw, cp));
  var cv = normalize(cross(cu, cw));
  return mat3x3<f32>(cu, cv, cw);
}

// sine wave around 0 with amplitude val
fn animate(val: vec3f, time_scale: f32, offset: f32) -> vec3f
{
  return val * sin(uniforms[0] * time_scale + offset);
}

@compute @workgroup_size(THREAD_COUNT, 1, 1)
fn preprocess(@builtin(global_invocation_id) id : vec3u)
{
  var time = uniforms[0];
  var spheresCount = i32(uniforms[2]);
  var boxesCount = i32(uniforms[3]);
  var torusCount = i32(uniforms[4]);
  var all_objects_count = spheresCount + boxesCount + torusCount;

  if (id.x >= u32(all_objects_count))
  {
    return;
  }

  // done once per object here instead of once per pixel in scene()
  var s = shapesb[id.x];

  var position = s.transform.xyz + animate(s.animate_transform.xyz, s.animate_transform.w, 0.0);

  // rotation and its animation amplitude are both in radians
  var angles = s.rotation.xyz + animate(s.animate_rotation.xyz, s.animate_rotation.w, 0.0);

  shapesb[id.x].transform_animated = vec4f(position, 0.0);
  shapesb[id.x].quat = quaternion_from_euler(angles);
}

@compute @workgroup_size(THREAD_COUNT, THREAD_COUNT, 1)
fn render(@builtin(global_invocation_id) id : vec3u)
{
  // unpack data
  var fragCoord = vec2f(f32(id.x), f32(id.y));
  var rez = vec2(uniforms[1]);
  var time = uniforms[0];

  // camera setup
  var lookfrom = vec3(uniforms[6], uniforms[7], uniforms[8]);
  var lookat = vec3(uniforms[9], uniforms[10], uniforms[11]);
  var camera = set_camera(lookfrom, lookat, 0.0);
  var ro = lookfrom;

  // get ray direction
  var uv = (fragCoord - 0.5 * rez) / rez.y;
  uv.y = -uv.y;
  var rd = camera * normalize(vec3(uv, 1.0));

  var march_result = march(ro, rd);
  var hit_point = ro + rd * march_result.depth;
  var color = get_light(hit_point, march_result.color, rd);

  if (uniforms[26] > 0.5 && march_result.outline)
  {
    color = int_to_rgb(i32(uniforms[28]));
  }

  // display the result (clamped so pow() in the gamma correction never sees a negative)
  color = linear_to_gamma(clamp(color, vec3f(0.0), vec3f(1.0)));
  fb[mapfb(id.xy, uniforms[1])] = vec4(color, 1.0);
}
