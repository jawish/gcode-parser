G28 ; Home all axes
G1 X10 Y20 Z5 F1500 ; Move to position
G1 X20 Y30 E5 ; Extrude while moving
M104 S200 ; Set extruder temperature
M140 S60 ; Set bed temperature
G92 E0 ; Reset extruder
G1 F3000 ; Set feed rate
G1 X50 Y50 Z10 ; Move to new position
M106 S255 ; Turn on fan
G1 X0 Y0 Z0 ; Return to origin 