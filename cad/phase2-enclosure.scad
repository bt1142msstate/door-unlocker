// Door Unlocker - Phase 2 enclosure first-pass CAD
// Units: millimeters
//
// This is a fit/print iteration model, not a final production enclosure.
// Verify all purchased components with calipers before printing.

$fn = 44;

show_shell = true;
show_back_plate = true;
show_component_blocks = true;
show_clearance_blocks = false;
show_labels = false;

case_w = 78;
case_d = 37;
case_h = 352;
wall = 3;
case_r = 7;
front_y = case_d / 2;

back_plate_w = 88;
back_plate_d = 4;
back_plate_h = 366;

solar_w = 50;
solar_d = 3;
solar_h = 80;
solar_z = 303;

led_w = 22;
led_d = 3;
led_h = 5;
led_z = 257;

servo_w = 40.5;
servo_d = 20.5;
servo_h = 40.5;
servo_z = 218;

servo_bay_w = 62;
servo_bay_h = 62;
servo_bay_z = 218;

electronics_bay_w = 64;
electronics_bay_h = 118;
electronics_bay_z = 137;

xiao_w = 17.8;
xiao_d = 11;
xiao_h = 21;

wago_w = 17;
wago_d = 20.5;
wago_h = 14.5;

buck_w = 60;
buck_d = 12;
buck_h = 40;

battery_w = 43;
battery_d = 22;
battery_h = 75;
battery_z = 44;

battery_slot_w = 49;
battery_slot_d = 28;
battery_slot_h = 84;
battery_slot_z = 47;

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

module shell_body() {
  difference() {
    color("#1e2420")
      rounded_prism([case_w, case_d, case_h], case_r);

    // Solar and LED shallow recesses.
    front_pocket(solar_w + 5, solar_h + 5, solar_z, 3.2);
    front_pocket(led_w + 4, led_h + 4, led_z, 4);

    // Main service openings.
    front_pocket(servo_bay_w, servo_bay_h, servo_bay_z, case_d - 6);
    front_pocket(electronics_bay_w, electronics_bay_h, electronics_bay_z, case_d - 6);
    front_pocket(battery_slot_w, battery_slot_h, battery_slot_z, battery_slot_d);

    // Bottom slide-up opening for battery cartridge.
    translate([0, front_y - battery_slot_d / 2 + 0.2, 3])
      cube([battery_slot_w, battery_slot_d + 0.6, 14], center = true);

    // Cable routing between bays.
    cable_slot(22, 185, 36);
    cable_slot(22, 174, 26);
    cable_slot(-18, 84, 32);

    // Service bay screw holes.
    screw_hole(-29, servo_bay_z + 25);
    screw_hole(29, servo_bay_z + 25);
    screw_hole(-29, servo_bay_z - 25);
    screw_hole(29, servo_bay_z - 25);
    screw_hole(-31, electronics_bay_z + 53);
    screw_hole(31, electronics_bay_z + 53);
    screw_hole(-31, electronics_bay_z - 53);
    screw_hole(31, electronics_bay_z - 53);
  }
}

module back_plate() {
  color("#2d332f")
    translate([0, -case_d / 2 - back_plate_d / 2 - 1, -7])
      rounded_prism([back_plate_w, back_plate_d, back_plate_h], 6);

  // Simple slide rails for the removable shell.
  color("#38413a") {
    translate([-case_w / 2 - 2, -case_d / 2 - 1.5, case_h / 2])
      cube([3.5, 5, case_h - 20], center = true);
    translate([case_w / 2 + 2, -case_d / 2 - 1.5, case_h / 2])
      cube([3.5, 5, case_h - 20], center = true);
  }
}

module solar_panel() {
  color("#2f6f9f")
    translate([0, front_y + solar_d / 2 + 0.2, solar_z])
      cube([solar_w, solar_d, solar_h], center = true);
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
    translate([0, front_y - 18, servo_z])
      cube([servo_w, servo_d, servo_h], center = true);

  color("#111111")
    translate([servo_w / 2 + 24, front_y + 4, servo_z + 7])
      cube([64, 4, 8], center = true);

  color("#0b0b0b")
    translate([0, front_y + 3, servo_z + 7])
      rotate([90, 0, 0])
        cylinder(h = 8, d = 18, center = true);
}

module xiao_block() {
  color("#23a06f")
    translate([-19, front_y - 18, electronics_bay_z + 21])
      cube([xiao_w, xiao_d, xiao_h], center = true);

  color("#dfe6e1")
    translate([-19, front_y - 11.8, electronics_bay_z + 29])
      cube([9, 3, 4], center = true);
}

module wago_pair() {
  for (zoff = [-10, 10]) {
    color("#f28b32")
      translate([20, front_y - 16, electronics_bay_z + 21 + zoff])
        cube([wago_w, wago_d, wago_h], center = true);
    color("#c9d0cb")
      translate([20, front_y - 8, electronics_bay_z + 21 + zoff])
        cube([wago_w + 2, 3, wago_h + 1], center = true);
  }
}

module buck_block() {
  color("#d7b546")
    translate([0, front_y - 18, electronics_bay_z - 36])
      cube([buck_w, buck_d, buck_h], center = true);
}

module battery_block() {
  color("#ef6c38")
    translate([0, front_y - 18, battery_z])
      cube([battery_w, battery_d, battery_h], center = true);

  // Small exposed pull lip. The cartridge is otherwise nearly flush.
  color("#111111")
    translate([0, front_y - 5, 4])
      cube([28, 4, 4], center = true);
}

module clearance_blocks() {
  color([1, 0.2, 0.2, 0.22]) {
    translate([0, front_y - 18, servo_z])
      cube([servo_w + 4, servo_d + 4, servo_h + 4], center = true);
    translate([0, front_y - 18, battery_z])
      cube([battery_w + 4, battery_d + 4, battery_h + 4], center = true);
    translate([0, front_y - 18, electronics_bay_z - 5])
      cube([electronics_bay_w - 4, 24, electronics_bay_h - 4], center = true);
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
if (show_shell) shell_body();
if (show_component_blocks) {
  solar_panel();
  pill_led();
  servo_block();
  xiao_block();
  wago_pair();
  buck_block();
  battery_block();
}
if (show_clearance_blocks) clearance_blocks();
if (show_labels) labels();
