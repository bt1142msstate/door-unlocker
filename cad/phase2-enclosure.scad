// Door Unlocker - Phase 2 enclosure first-pass CAD
// Units: millimeters
//
// This is a fit/print iteration model, not a final production enclosure.
// Verify all purchased components with calipers before printing.
// Defaults target Bambu Lab PLA Pure on a Bambu Lab P1S with a 0.4mm nozzle.

$fn = 44;

show_shell = true;
show_back_plate = true;
show_service_cover = true;
show_component_blocks = true;
show_command_strips = true;
show_clearance_blocks = false;
show_labels = false;

case_w = 72;
case_d = 34;
case_h = 264;
wall = 3.2;
case_r = 7;
front_y = case_d / 2;

back_plate_w = 50.8;
back_plate_d = 7;
back_plate_h = case_h;
back_plate_z = (case_h - back_plate_h) / 2;

command_strip_w = 0.875 * 25.4; // 3M Command 17217 X-Large, 7/8 in
command_strip_h = 4.375 * 25.4; // 3M Command 17217 X-Large, 4 3/8 in
command_strip_d = 0.0625 * 25.4; // 3M Command 17217 listed depth, 1/16 in
command_strip_gap = 4;
command_strip_x_center = (command_strip_w + command_strip_gap) / 2;
command_strip_z_center_offset = (command_strip_h + command_strip_gap) / 2;
command_strip_side_margin = (back_plate_w - (2 * command_strip_w + command_strip_gap)) / 2;
command_strip_top_margin = (back_plate_h - (2 * command_strip_h + 2 * command_strip_z_center_offset - command_strip_h)) / 2;

mount_rail_spacing = 30;
mount_rail_angle = 60;
mount_rail_neck_w = 8;
mount_rail_depth = 5.5;
mount_rail_head_w = mount_rail_neck_w + 2 * mount_rail_depth / tan(mount_rail_angle);
mount_rail_clearance = 0.40;
mount_rail_end_margin = 10;
mount_channel_end_margin = 9;
detent_w = 8;
detent_d = 1.2;
detent_h = 3;
detent_z = case_h - 18;
mount_rail_bottom_z = mount_rail_end_margin;
mount_rail_top_z = case_h - mount_rail_end_margin;
mount_rail_center_z = (mount_rail_bottom_z + mount_rail_top_z) / 2;
mount_rail_h = mount_rail_top_z - mount_rail_bottom_z;
mount_channel_bottom_z = mount_channel_end_margin;
mount_channel_top_z = case_h - mount_channel_end_margin;
mount_channel_center_z = (mount_channel_bottom_z + mount_channel_top_z) / 2;
mount_channel_h = mount_channel_top_z - mount_channel_bottom_z;

solar_w = 60;
solar_d = 3;
solar_h = 220;
solar_z = 130;

led_w = 22;
led_d = 3;
led_h = 5;
led_z = 233;

servo_w = 40.5;
servo_d = 20;
servo_h = 37.5;
servo_z = 88.9;

servo_bay_w = 56;
servo_bay_h = 52;
servo_bay_z = 88.9;
servo_front_pocket_w = servo_bay_w;
servo_front_pocket_d = case_d - 6;
servo_front_pocket_h = 58;
servo_front_pocket_z = 89;
servo_adjustment_offsets = [-5, 0, 5];
servo_cradle_w = 42;
servo_cradle_d = 23;
servo_cradle_h = 3;
servo_notch_w = 6;
servo_notch_d = 20;
servo_notch_h = 2.2;

electronics_bay_w = 64;
electronics_bay_h = 146;
electronics_bay_z = 113;

service_cover_w = 66;
service_cover_d = 2.2;
service_cover_h = case_h - 12;
service_cover_z = case_h / 2;
service_cover_rail_neck_w = 3.2;
service_cover_rail_depth = 2.0;
service_cover_rail_head_w = service_cover_rail_neck_w + 2 * service_cover_rail_depth / tan(mount_rail_angle);
service_cover_rail_h = service_cover_h - 18;

xiao_w = 21;
xiao_d = 1.6;
xiao_h = 17.8;
xiao_x = 0;
xiao_y = 6;
xiao_z = 68;

breadboard_w = 35;
breadboard_d = 8.5;
breadboard_h = 47;
breadboard_x = 0;
breadboard_y = 0;
breadboard_z = 68;

splitter_w = 13.5;
splitter_d = 13;
splitter_h = 32;
splitter_x_centers = [-6.75, 6.75];
splitter_y = 6.5;
splitter_z = 169.5;

buck_w = 40;
buck_d = 10;
buck_h = 60;
buck_y = 0;
buck_z = 122.5;

battery_w = 43;
battery_d = 22;
battery_h = 75;
battery_y = 2;
battery_z = 224;

battery_slot_w = 46.5;
battery_slot_d = 25;
battery_slot_h = 80.5;
battery_slot_z = 224;

// Rear-wall service harness. Raised lips preserve the full structural wall
// thickness and keep the harness attached to the sled when the cover is off.
wire_channel_z_start = 42;
wire_channel_z_end = 190;
wire_channel_h = wire_channel_z_end - wire_channel_z_start;
wire_channel_z = (wire_channel_z_start + wire_channel_z_end) / 2;
wire_channel_rear_y = -case_d / 2 + wall;
wire_channel_rib_w = 1;
wire_channel_retainer_spacing = 27;
wire_lane_x = [-28, -22.8, -17.6, -8, -4, 0, 4, 8, 22.8, 28];
wire_lane_clear_w = [4.2, 4.2, 4.2, 3, 3, 3, 3, 3, 4.2, 4.2];
wire_lane_rib_d = [3.4, 3.4, 3.4, 2.2, 2.2, 2.2, 2.2, 2.2, 3.4, 3.4];
wire_lane_od = [3, 3, 3, 1.8, 1.8, 1.8, 1.8, 1.8, 3, 3];
wire_lane_retainer_overhang = [1, 1, 1, 0.4, 0.4, 0.4, 0.4, 0.4, 1, 1];
wire_lane_colors = ["#e05252", "#e05252", "#e05252", "#f5c542", "#e05252", "#171a18", "#e05252", "#171a18", "#171a18", "#171a18"];
wire_lane_active = [true, true, false, true, true, true, true, true, true, true];

module rounded_prism(size, r) {
  linear_extrude(height = size[2], center = false)
    offset(r = r)
      square([size[0] - 2 * r, size[1] - 2 * r], center = true);
}

module front_pocket(w, h, z, depth) {
  translate([0, front_y - depth / 2 + 0.2, z])
    cube([w, depth + 0.6, h], center = true);
}

module screw_hole(x, z, d = 3.4, depth = 12) {
  translate([x, front_y - depth / 2 + 0.5, z])
    rotate([90, 0, 0])
      cylinder(h = depth + 1, d = d, center = true);
}

module cable_slot(x, z, h = 26) {
  translate([x, front_y - 10, z])
    cube([5, 16, h], center = true);
}

module wire_routing_trough(x, clear_w, rib_d, retainer_overhang) {
  // Two shallow ribs create an open service groove. Partial opposing nibs hold
  // the wire without turning the lane into a closed tunnel that must be threaded.
  for (side = [-1, 1]) {
    translate([
      x + side * (clear_w / 2 + wire_channel_rib_w / 2),
      wire_channel_rear_y + rib_d / 2,
      wire_channel_z
    ])
      cube([wire_channel_rib_w, rib_d, wire_channel_h], center = true);

    for (index = [0 : 2])
      translate([
        x + side * (clear_w / 2 + wire_channel_rib_w / 2) - side * retainer_overhang / 2,
        wire_channel_rear_y + rib_d - 0.35,
        wire_channel_z_start + wire_channel_retainer_spacing / 2 + index * wire_channel_retainer_spacing
      ])
        cube([wire_channel_rib_w + retainer_overhang, 0.7, 2.2], center = true);
  }
}

module wire_routing_channels() {
  color("#38413a")
    for (index = [0 : len(wire_lane_x) - 1])
      wire_routing_trough(
        wire_lane_x[index],
        wire_lane_clear_w[index],
        wire_lane_rib_d[index],
        wire_lane_retainer_overhang[index]
      );
}

module wire_harness_preview() {
  for (index = [0 : len(wire_lane_x) - 1])
    if (wire_lane_active[index])
      color(wire_lane_colors[index])
        translate([
          wire_lane_x[index],
          wire_channel_rear_y + wire_lane_od[index] / 2 + 0.2,
          wire_channel_z
        ])
          cylinder(h = wire_channel_h, d = wire_lane_od[index], center = true);
}

module battery_top_guides() {
  guide_bottom_z = battery_z - battery_h / 2;
  guide_h = case_h - guide_bottom_z;
  color("#38413a")
    for (x = [-24.1, 24.1])
      translate([x, 0, guide_bottom_z + guide_h / 2])
        rounded_prism([3.2, 8, guide_h], 1.2);
}

module dovetail_profile(neck_w, head_w, depth) {
  polygon(points = [
    [-neck_w / 2, 0],
    [neck_w / 2, 0],
    [head_w / 2, depth],
    [-head_w / 2, depth]
  ]);
}

module captive_dovetail_rail(length = mount_rail_h) {
  linear_extrude(height = length, center = true)
    dovetail_profile(mount_rail_neck_w, mount_rail_head_w, mount_rail_depth);
}

module captive_dovetail_channel(length = mount_channel_h) {
  channel_neck_w = mount_rail_neck_w + mount_rail_clearance * 2;
  channel_depth = mount_rail_depth + mount_rail_clearance;
  channel_head_w = channel_neck_w + 2 * channel_depth / tan(mount_rail_angle);

  linear_extrude(height = length, center = true)
    dovetail_profile(channel_neck_w, channel_head_w, channel_depth);
}

module service_cover_dovetail_rail(length = service_cover_rail_h) {
  linear_extrude(height = length, center = true)
    dovetail_profile(service_cover_rail_neck_w, service_cover_rail_head_w, service_cover_rail_depth);
}

module servo_adjustment_notches() {
  for (offset = servo_adjustment_offsets) {
    notch_z = servo_z + offset - servo_h / 2 - servo_cradle_h / 2;

    // A removable cradle sits on left/right ledges so servo height can shift
    // without loosening the tight side support in the bay.
    color("#75d99f") {
      for (x = [-20.5, 20.5])
        translate([x, front_y - 15, notch_z])
          cube([servo_notch_w, servo_notch_d, servo_notch_h], center = true);
    }
  }

  color("#2f6f9f")
    translate([0, front_y - 15, servo_z - servo_h / 2 - servo_cradle_h / 2])
      cube([servo_cradle_w, servo_cradle_d, servo_cradle_h], center = true);
}

module shell_body() {
  difference() {
    color("#1e2420")
      rounded_prism([case_w, case_d, case_h], case_r);

    // Matching female channels for the door mounting plate's captive dovetail rails.
    for (x = [-mount_rail_spacing / 2, mount_rail_spacing / 2])
      translate([x, -case_d / 2 - 0.2, mount_channel_center_z])
        captive_dovetail_channel();

    // The solar panels are planned as a thin external service-cover/front-face
    // skin. Do not cut a full 220mm panel recess until the exact split around
    // the front-exposed servo pocket is modeled.
    front_pocket(18, 8, solar_z + 96, 3.2);
    front_pocket(led_w + 4, led_h + 4, led_z, 4);

    // Main service openings.
    // Front-exposed servo pocket: the servo can protrude forward while the
    // bay/cradle keeps side, bottom, and rear support.
    front_pocket(servo_front_pocket_w, servo_front_pocket_h, servo_front_pocket_z, servo_front_pocket_d);
    front_pocket(electronics_bay_w, electronics_bay_h, electronics_bay_z, case_d - 6);
    front_pocket(battery_slot_w, battery_slot_h, battery_slot_z, battery_slot_d);

    // Top-loading battery mouth. The full-height service opening exposes the
    // internal guides; this top relief lets the pack enter without removing
    // the enclosure sled from the door plate.
    translate([0, front_y - battery_slot_d / 2 + 0.2, case_h - 3])
      cube([battery_slot_w, battery_slot_d + 0.6, 8], center = true);

    // Cable routing between bays.
    cable_slot(22, 188, 24);
    cable_slot(22, 154, 24);
    cable_slot(-18, 93, 28);

    // Service bay screw holes.
    screw_hole(-26, servo_bay_z + 23);
    screw_hole(26, servo_bay_z + 23);
    screw_hole(-26, servo_bay_z - 23);
    screw_hole(26, servo_bay_z - 23);
    screw_hole(-29, electronics_bay_z + 40);
    screw_hole(29, electronics_bay_z + 40);
    screw_hole(-29, electronics_bay_z - 40);
    screw_hole(29, electronics_bay_z - 40);
  }
}

module back_plate() {
  color("#2d332f")
    translate([0, -case_d / 2 - back_plate_d / 2 - 1, back_plate_z])
      rounded_prism([back_plate_w, back_plate_d, back_plate_h], 6);

  // Open-ended captive male dovetail rails hide behind the enclosure.
  color("#38413a") {
    for (x = [-mount_rail_spacing / 2, mount_rail_spacing / 2])
      translate([x, -case_d / 2 - 1, mount_rail_center_z])
        captive_dovetail_rail();
  }

  // Small hidden detent instead of visible load stops, so removal stays easy.
  color("#5eb8ff")
    translate([0, -case_d / 2 - 0.55, detent_z])
      rounded_prism([detent_w, detent_d, detent_h], 1);
}

module command_strips() {
  // Four 17217 X-Large picture-hanging pairs: 4 3/8 x 7/8 x 1/16 in each.
  // The two-column layout is intentionally tight on a 2in plate: about 1.2mm side margin.
  color([0.95, 0.97, 0.94, 0.86]) {
    for (x = [-command_strip_x_center, command_strip_x_center])
      for (z = [
        case_h / 2 - command_strip_z_center_offset,
        case_h / 2 + command_strip_z_center_offset
      ])
        translate([
          x,
          -case_d / 2 - back_plate_d - 1 - command_strip_d / 2,
          z - command_strip_h / 2
        ])
          rounded_prism([command_strip_w, command_strip_d, command_strip_h], 2);
  }
}

module service_cover() {
  color("#3c453f")
    translate([0, front_y + service_cover_d / 2 + 0.8, service_cover_z - service_cover_h / 2])
      rounded_prism([service_cover_w, service_cover_d, service_cover_h], 5);

  // Full-height cover rails: the cover can slide off separately for service.
  color("#75d99f") {
    for (x = [-service_cover_w / 2 + 6, service_cover_w / 2 - 6])
      translate([x, front_y + service_cover_d + 0.4, service_cover_z])
        service_cover_dovetail_rail();
  }

  color("#151a16") {
    for (x = [-28, 28], z = [service_cover_z - 94, service_cover_z + 94])
      translate([x, front_y + service_cover_d + 1.2, z])
        rotate([90, 0, 0])
          cylinder(h = 1.2, d = 3.6, center = true);
  }
}

module solar_panel() {
  color("#2f6f9f")
    translate([0, front_y + solar_d / 2 + 0.2, solar_z - 55])
      cube([solar_w, solar_d, 110], center = true);

  // The second full panel overlaps the servo opening. Keep it translucent red
  // until a smaller panel, external carrier, or different face layout is chosen.
  color([1, 0.25, 0.2, 0.28])
    translate([0, front_y + solar_d / 2 + 0.2, solar_z + 55])
      cube([solar_w, solar_d, 110], center = true);
}

module pill_led() {
  color("#71f0a1")
    translate([0, front_y + led_d / 2 + 0.4, led_z])
      hull() {
        translate([-led_w / 2 + led_h / 2, 0, 0])
          rotate([90, 0, 0])
            cylinder(h = led_d, d = led_h, center = true);
        translate([led_w / 2 - led_h / 2, 0, 0])
          rotate([90, 0, 0])
            cylinder(h = led_d, d = led_h, center = true);
      }
}

module servo_block() {
  color("#4a64d8")
    translate([0, front_y + 1, servo_z])
      cube([servo_w, servo_d, servo_h], center = true);

  color("#111111")
    translate([servo_w / 2 + 24, front_y + 4, servo_z + 6])
      cube([64, 4, 8], center = true);

  color("#0b0b0b")
    translate([0, front_y + 3, servo_z + 6])
      rotate([90, 0, 0])
        cylinder(h = 8, d = 18, center = true);
}

module xiao_block() {
  color("#b8242d")
    translate([breadboard_x, breadboard_y, breadboard_z])
      cube([breadboard_w, breadboard_d, breadboard_h], center = true);

  color("#23a06f")
    translate([xiao_x, xiao_y, xiao_z])
      cube([xiao_w, xiao_d, xiao_h], center = true);

  color("#dfe6e1")
    translate([xiao_x, xiao_y + 6.2, xiao_z + 7])
      cube([9, 3, 4], center = true);
}

module inline_splitter_pair() {
  for (x = splitter_x_centers) {
    color("#c9d0cb")
      translate([x, splitter_y, splitter_z])
        cube([splitter_w, splitter_d, splitter_h], center = true);
    for (lever = [[-3.2, 10.5], [3.2, 10.5], [0, -9]]) {
      color("#f28b32")
        translate([x + lever[0], splitter_y + splitter_d / 2 + 1.2, splitter_z + lever[1]])
          cube([4.1, 2.4, 12.5], center = true);
    }
  }
}

module buck_block() {
  color("#d7b546")
    translate([0, buck_y, buck_z])
      cube([buck_w, buck_d, buck_h], center = true);
}

module battery_block() {
  color("#ef6c38")
    translate([0, battery_y, battery_z])
      cube([battery_w, battery_d, battery_h], center = true);

  // Small upper pull lip. The cartridge loads from the top and seats on the
  // fixed XT30 dock below it.
  color("#111111")
    translate([0, front_y - 5, battery_z + battery_h / 2 + 3])
      cube([28, 3.5, 4], center = true);

  // Fixed lower dock shown as a component-fit envelope.
  color("#f0b323")
    translate([0, battery_y, battery_z - battery_h / 2 - 3.5])
      cube([13, 9, 7], center = true);
}

module clearance_blocks() {
  color([1, 0.2, 0.2, 0.22]) {
    translate([0, front_y + 1, servo_z])
      cube([servo_w + 1.2, servo_d + 1.2, servo_h + 1.2], center = true);
    translate([0, front_y - 18, battery_z])
      cube([battery_w + 3, battery_d + 3, battery_h + 5.5], center = true);
    translate([0, front_y - 18, electronics_bay_z - 5])
      cube([electronics_bay_w - 3, 24, electronics_bay_h - 3], center = true);
  }
}

module labels() {
  color("#f3f7f1") {
    translate([-58, front_y + 3, solar_z])
      rotate([90, 0, 0])
        linear_extrude(0.6)
          text("solar", size = 5, halign = "center");
    translate([-58, front_y + 3, servo_z])
      rotate([90, 0, 0])
        linear_extrude(0.6)
          text("servo", size = 5, halign = "center");
    translate([-58, front_y + 3, electronics_bay_z])
      rotate([90, 0, 0])
        linear_extrude(0.6)
          text("electronics", size = 5, halign = "center");
    translate([-58, front_y + 3, battery_z])
      rotate([90, 0, 0])
        linear_extrude(0.6)
          text("battery", size = 5, halign = "center");
  }
}

if (show_back_plate) back_plate();
if (show_command_strips) command_strips();
if (show_shell) {
  shell_body();
  wire_routing_channels();
  battery_top_guides();
}
if (show_service_cover) service_cover();
if (show_component_blocks) {
  solar_panel();
  pill_led();
  servo_block();
  servo_adjustment_notches();
  xiao_block();
  inline_splitter_pair();
  wire_harness_preview();
  buck_block();
  battery_block();
}
if (show_clearance_blocks) clearance_blocks();
if (show_labels) labels();
