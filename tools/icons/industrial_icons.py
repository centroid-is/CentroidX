#!/usr/bin/env python3
"""The industrial glyphs of the TfcIcons font.

Material and Font Awesome between them have no motor, no VFD, no proximity
sensor and no pump, so a mimic page that needed one had to settle for
`precision_manufacturing` or a coloured box. These are drawn here instead.

Run this module to rebuild the font and a proof sheet::

    tools/icons/build.sh

Every glyph is drawn in the design space described in ``icon_builder``: a
1000x1000 square, origin top-left, y pointing down, artwork inside a 60-unit
margin. Code points are allocated from U+E809 upwards -- U+E800..U+E808 are the
Fontello glyphs already in the font and in saved pages, and the builder refuses
to overwrite them.
"""

from __future__ import annotations

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from icon_builder import (  # noqa: E402
    BUTT,
    CX,
    CY,
    EM,
    MITER,
    ROUND,
    ROUND_JOIN,
    SQUARE,
    STROKE,
    THIN,
    Ink,
    arc,
    arrow,
    box,
    circle,
    curve,
    ellipse,
    fill,
    hexagon,
    merge,
    merge_into_font,
    outline,
    poly,
    rect,
    ring,
    rotated,
    sine,
    stroke,
    subtract,
)

# --- Shared sub-assemblies -------------------------------------------------


def gear(cx, cy, r_tip=200, teeth=8, tooth_w=88, hub=56):
    """A spur gear: a solid wheel, `teeth` teeth out to `r_tip`, and a bore.

    The wheel is solid rather than a rim ring -- a ring put a third concentric
    white line inside every gear, and two geared icons side by side came out as
    speckle at 24px. Teeth stand 28% of the tip radius proud of the wheel,
    which is about what a real involute tooth looks like; much more and the
    gear reads as a star.
    """
    r_body = r_tip * 0.72
    parts = [circle(cx, cy, r_body)]
    for i in range(teeth):
        a = math.radians(360 * i / teeth)
        ux, uy = math.cos(a), math.sin(a)
        parts.append(
            stroke(
                [
                    (cx + ux * (r_body - 20), cy + uy * (r_body - 20)),
                    (cx + ux * r_tip, cy + uy * r_tip),
                ],
                tooth_w,
                SQUARE,
            )
        )
    return subtract(merge(*parts), circle(cx, cy, hub))

def din_module(x0, y0, x1, y1, terminals=3, r=36):
    """A DIN-rail device: a rounded body with terminal slots top and bottom."""
    body = rect(x0, y0, x1 - x0, y1 - y0, r)
    slots = []
    span = (x1 - x0) - 120
    w = min(96, span / (terminals * 1.7))
    for i in range(terminals):
        cx = x0 + 60 + span * (i + 0.5) / terminals
        slots.append(box(cx - w / 2, y0 - 10, cx + w / 2, y0 + 92, 16))
        slots.append(box(cx - w / 2, y1 - 92, cx + w / 2, y1 + 10, 16))
    return subtract(body, merge(*slots))


def motor_body(x0, x1, y0, y1, ribs=3):
    """The finned frame shared by `motor` and `gearmotor`.

    The rib slots stop short of the top and bottom edges. Cutting all the way
    through left four free-floating bars that read as a barcode, not a motor.
    """
    frame = rect(x0, y0, x1 - x0, y1 - y0, 46)
    inset = (y1 - y0) * 0.17
    cuts = []
    for i in range(ribs):
        cx = x0 + (x1 - x0) * (i + 1) / (ribs + 1)
        cuts.append(box(cx - 31, y0 + inset, cx + 31, y1 - inset, 14))
    return subtract(frame, merge(*cuts))

# --- Sensors ---------------------------------------------------------------


def sensor_proximity():
    """Inductive barrel sensor, sensing face to the right."""
    barrel = rect(90, 380, 430, 240, 26)
    threads = merge(*[box(x, 370, x + 30, 630) for x in (300, 358, 416, 474)])
    return (
        Ink()
        .add(subtract(barrel, threads))
        .add(stroke([(110, 500), (60, 500)], 84, BUTT))
        .add(rect(520, 350, 52, 300, 14))
        .add(arc(590, 500, 150, -48, 48, 64, ROUND))
        .add(arc(590, 500, 262, -42, 42, 64, ROUND))
    )


def sensor_photoeye():
    """Through-beam photoelectric sensor: emitter, beam, receiver."""
    left = subtract(rect(70, 290, 200, 420, 34), circle(190, 500, 62))
    right = subtract(rect(730, 290, 200, 420, 34), circle(810, 500, 62))
    beam = stroke([(300, 500), (700, 500)], 60, BUTT, MITER, False, [96, 72])
    return Ink().add(left, right, beam)


def sensor_limit_switch():
    """Roller-lever limit switch."""
    return (
        Ink()
        .add(rect(110, 430, 510, 440, 44))
        .add(box(345, 350, 425, 440))
        .add(stroke([(385, 392), (792, 194)], 72, ROUND))
        .add(circle(385, 392, 48))
        .add(ring(820, 180, 88, 72))
        .add(box(210, 870, 290, 940, 12), box(440, 870, 520, 940, 12))
    )

def sensor_temperature():
    """Temperature probe: connection head, hex fitting, stem and bulb.

    The bulb is what stops this reading as a bolt -- an earlier pass drew
    graduation marks up the stem and everyone saw a thread.
    """
    return (
        Ink()
        .add(rect(312, 60, 376, 154, 40))
        .add(hexagon(500, 330, 336, 184))
        .add(stroke([(500, 406), (500, 772)], 76, BUTT))
        .add(circle(500, 792, 126))
    )

def sensor_pressure():
    """Pressure transmitter: dial, pointer, and the process connection."""
    return (
        Ink()
        .add(ring(500, 340, 254, 82))
        .add(stroke([(500, 340), (672, 198)], 66, ROUND))
        .add(circle(500, 340, 56))
        .add(box(436, 578, 564, 690))
        .add(rect(286, 684, 428, 106, 24))
        .add(rect(388, 786, 224, 148, 20))
    )

def sensor_level():
    """Level probe dipped into a part-full vessel.

    The vessel is open at the top and the probe reaches down through it. A
    closed rectangle with a wave in it is an image icon, not a level sensor --
    two earlier passes proved it.
    """
    vessel = subtract(outline(170, 200, 830, 876, 76, 96), box(250, 120, 750, 268))
    surface = merge(
        box(250, 592, 750, 812, 26),
        circle(372, 592, 60),
        circle(628, 592, 60),
    )
    return (
        Ink()
        .add(vessel)
        .add(subtract(surface, circle(500, 584, 66)))
        .add(rect(404, 60, 192, 92, 20))
        .add(stroke([(500, 110), (500, 760)], 66, BUTT))
    )

def sensor_flow():
    """Inline flow meter: pipe, meter body, direction arrow."""
    return (
        Ink()
        .add(stroke([(60, 400), (940, 400)], STROKE, BUTT))
        .add(stroke([(60, 700), (940, 700)], STROKE, BUTT))
        .add(outline(330, 235, 670, 865, STROKE, 40))
        .add(arrow(150, 550, 862, 550, 62, 156))
    )


def sensor_encoder():
    """Rotary encoder: slotted disc, hub and connector."""
    slots = merge(
        *[
            stroke(
                [
                    (500 + math.cos(math.radians(a)) * 150,
                     500 + math.sin(math.radians(a)) * 150),
                    (500 + math.cos(math.radians(a)) * 252,
                     500 + math.sin(math.radians(a)) * 252),
                ],
                70,
                BUTT,
            )
            for a in range(0, 360, 60)
        ]
    )
    return (
        Ink()
        .add(ring(500, 490, 318, 76))
        .add(slots)
        .add(circle(500, 490, 84))
        .add(rect(408, 838, 184, 100, 16))
    )


def load_cell():
    """Shear-beam load cell under load."""
    cutout = merge(
        circle(330, 476, 96), circle(670, 476, 96), box(330, 380, 670, 572)
    )
    return (
        Ink()
        .add(arrow(500, 56, 500, 292, 76, 148))
        .add(subtract(rect(160, 326, 680, 300, 54), cutout))
        .add(box(280, 626, 720, 712))
        .add(rect(120, 712, 760, 92, 20))
    )

# --- Motors and drives -----------------------------------------------------


def motor():
    """IEC frame motor, side view: fan cowl, finned frame, terminal box, feet."""
    return (
        Ink()
        .add(rect(60, 340, 96, 340, 30))
        .add(motor_body(178, 748, 300, 726))
        .add(rect(382, 176, 186, 134, 20))
        .add(rect(748, 464, 182, 92, 12))
        .add(rect(222, 726, 132, 86, 10), rect(572, 726, 132, 86, 10))
    )


def motor_circle():
    """The ISA/P&ID motor symbol: a circle with an M in it."""
    return (
        Ink()
        .add(ring(500, 500, 350, 80))
        .add(
            stroke(
                [(348, 654), (348, 346), (500, 556), (652, 346), (652, 654)],
                74,
                BUTT,
                MITER,
            )
        )
    )


def gearmotor():
    """Motor driving a gear unit."""
    return (
        Ink()
        .add(motor_body(56, 462, 326, 672, 3))
        .add(rect(190, 244, 158, 86, 16))
        .add(rect(92, 672, 116, 76, 10), rect(316, 672, 116, 76, 10))
        .add(box(462, 460, 548, 540))
        .add(gear(714, 500, 224, 7, 112, 70))
    )

def servo_motor():
    """Servo motor: feedback can at the rear, power and feedback connectors.

    Deliberately smooth-sided -- the cooling ribs are `motor`'s signature, and
    the two have to be told apart at 24px.
    """
    can = subtract(rect(56, 330, 152, 340, 44), circle(132, 500, 78))
    return (
        Ink()
        .add(merge(can, circle(132, 500, 30)))
        .add(rect(246, 252, 496, 496, 56))
        .add(rect(756, 444, 174, 112, 14))
        .add(rect(318, 152, 122, 106, 16), rect(510, 152, 122, 106, 16))
    )


def gearbox():
    """A gear unit: the housing with its gear train showing through.

    Drawn in negative -- a solid housing with the gears knocked out of it.
    Outlined gears inside an outlined housing put five thin white lines within
    a few units of each other and the whole thing read as speckle at 24px.
    """
    return (
        Ink()
        .add(
            subtract(
                rect(104, 214, 792, 572, 56),
                merge(gear(372, 498, 190, 7, 100, 58), gear(694, 420, 138, 6, 80, 42)),
            )
        )
        .add(box(60, 460, 142, 540))
        .add(box(858, 382, 940, 458))
    )

def vfd():
    """Frequency converter: the IEC power-converter square, DC in, AC out."""
    return (
        Ink()
        .add(outline(126, 126, 874, 874, 78, 44))
        .add(stroke([(196, 804), (804, 196)], 70, BUTT))
        .add(stroke([(224, 286), (438, 286)], 60, ROUND))
        .add(stroke([(224, 384), (438, 384)], 60, ROUND, MITER, False, [58, 52]))
        .add(sine(566, 812, 688, 84, 1.0, 62))
    )


# --- Pumps, valves and fluid handling --------------------------------------


def pump():
    """Centrifugal pump: swept impeller in a volute, suction in, discharge up."""
    vanes = merge(
        *[
            rotated(
                lambda pt: fill(
                    [
                        pt(96, -34),
                        ((pt(190, -88)), (pt(262, -54)), (pt(282, 22))),
                        (pt(214, 44)),
                        ((pt(190, -6)), (pt(150, -22)), (pt(96, 26))),
                    ]
                ),
                440,
                500,
                a,
            )
            for a in (0, 90, 180, 270)
        ]
    )
    return (
        Ink()
        .add(subtract(circle(440, 500, 300), vanes))
        .add(box(354, 150, 526, 260))
        .add(rect(316, 84, 248, 78, 20))
        .add(box(84, 442, 170, 558))
        .add(rect(54, 400, 66, 200, 18))
        .add(rect(190, 824, 540, 84, 22))
    )


def pump_circle():
    """The P&ID centrifugal pump: circle, suction in, discharge up, impeller."""
    return (
        Ink()
        .add(ring(500, 592, 268, 78))
        .add(poly([(398, 452), (398, 732), (656, 592)]))
        .add(stroke([(60, 592), (254, 592)], 76, BUTT))
        .add(stroke([(500, 306), (500, 76)], 76, BUTT))
    )

def valve():
    """Hand-operated valve: the bowtie body with a stem and handwheel."""
    return (
        Ink()
        .add(poly([(140, 420), (140, 830), (500, 625)]))
        .add(poly([(860, 420), (860, 830), (500, 625)]))
        .add(box(458, 300, 542, 640))
        .add(rect(268, 214, 464, 92, 30))
    )


def valve_solenoid():
    """Solenoid valve: the bowtie body under an IEC solenoid actuator."""
    return (
        Ink()
        .add(poly([(140, 460), (140, 866), (500, 663)]))
        .add(poly([(860, 460), (860, 866), (500, 663)]))
        .add(box(458, 330, 542, 678))
        .add(outline(286, 120, 714, 326, 72))
        .add(stroke([(342, 276), (658, 170)], 62, BUTT))
    )


def valve_actuated():
    """Pneumatically actuated valve: bowtie body under a diaphragm actuator."""
    return (
        Ink()
        .add(poly([(140, 458), (140, 868), (500, 663)]))
        .add(poly([(860, 458), (860, 868), (500, 663)]))
        .add(box(458, 356, 542, 678))
        .add(
            curve(
                [
                    (238, 356),
                    ((238, 96), (762, 96), (762, 356)),
                ],
                74,
                BUTT,
                ROUND_JOIN,
            )
        )
        .add(stroke([(200, 356), (800, 356)], 74, ROUND))
    )


def fan():
    """Fan or blower: three swept blades in a ring."""
    blades = merge(
        *[
            rotated(
                lambda pt: fill(
                    [
                        pt(86, -52),
                        ((pt(210, -186)), (pt(322, -84)), (pt(300, 48))),
                        (pt(196, 74)),
                        ((pt(214, -18)), (pt(168, -54)), (pt(86, 20))),
                    ]
                ),
                500,
                500,
                a,
            )
            for a in (-90, 30, 150)
        ]
    )
    return (
        Ink()
        .add(ring(500, 500, 386, 72))
        .add(blades)
        .add(circle(500, 500, 92))
    )


def compressor():
    """Air compressor: receiver, pump with a finned head, motor, legs."""
    head = subtract(
        rect(306, 132, 236, 150, 22),
        merge(box(296, 176, 552, 214), box(296, 236, 552, 274)),
    )
    return (
        Ink()
        .add(rect(90, 500, 800, 310, 155))
        .add(head)
        .add(rect(322, 270, 204, 250, 26))
        .add(rect(570, 300, 240, 220, 46))
        .add(box(504, 380, 586, 448))
        .add(stroke([(250, 790), (214, 940)], 70, BUTT))
        .add(stroke([(730, 790), (766, 940)], 70, BUTT))
    )


def tank():
    """Process tank: dished ends, legs, a nozzle on top."""
    shell = subtract(
        merge(
            rect(160, 220, 680, 620, 130),
        ),
        rect(232, 292, 536, 476, 76),
    )
    return (
        Ink()
        .add(shell)
        .add(box(430, 100, 570, 240))
        .add(rect(356, 60, 288, 76, 20))
        .add(stroke([(250, 790), (206, 930)], 66, BUTT))
        .add(stroke([(750, 790), (794, 930)], 66, BUTT))
    )


# --- I/O, control and electrical -------------------------------------------


def io_module():
    """A DIN-rail I/O terminal with a channel LED column."""
    body = din_module(210, 110, 790, 890, 3)
    leds = merge(*[circle(500, y, 52) for y in (330, 470, 610)])
    return Ink().add(subtract(body, leds))


def io_digital():
    """Digital I/O module: a square wave on the faceplate."""
    wave = stroke(
        [(300, 610), (300, 420), (430, 420), (430, 610), (560, 610),
         (560, 420), (690, 420)],
        62,
        BUTT,
        MITER,
    )
    return Ink().add(subtract(din_module(210, 110, 790, 890, 3), wave))


def io_analog():
    """Analogue I/O module: a sine on the faceplate."""
    return Ink().add(
        subtract(din_module(210, 110, 790, 890, 3), sine(300, 700, 500, 96, 1.0, 62))
    )


def plc():
    """PLC: a backplane with a CPU and I/O cards."""
    rail = rect(60, 210, 880, 580, 44)
    cards = merge(
        *[box(x, 270, x + 96, 730, 14) for x in (330, 470, 610, 750)]
    )
    cpu = merge(
        box(130, 270, 270, 730, 14),
    )
    leds = merge(circle(200, 344, 38), circle(200, 452, 38))
    return Ink().add(subtract(rail, merge(cards, subtract(cpu, leds))))


def hmi_panel():
    """Operator panel: bezel, screen, a row of function keys."""
    return (
        Ink()
        .add(outline(110, 150, 890, 830, 78, 36))
        .add(box(216, 256, 784, 624, 16))
        .add(*[box(x, 690, x + 118, 762, 14) for x in (216, 386, 556, 726)])
    )


def cabinet():
    """Control cabinet: double doors, handles, plinth."""
    return (
        Ink()
        .add(outline(120, 100, 880, 830, 76, 30))
        .add(box(464, 140, 536, 790))
        .add(box(330, 400, 400, 530, 20), box(600, 400, 670, 530, 20))
        .add(box(180, 830, 300, 930), box(700, 830, 820, 930))
    )


def power_supply():
    """DIN-rail power supply: AC in, DC out, adjustment pot."""
    body = din_module(200, 120, 800, 880, 2)
    marks = merge(
        sine(300, 700, 348, 62, 1.0, 58),
        stroke([(330, 596), (670, 596)], 58, ROUND),
        stroke([(330, 690), (670, 690)], 58, ROUND, MITER, False, [58, 52]),
    )
    return Ink().add(subtract(body, marks))


def circuit_breaker():
    """Motor-protective circuit breaker: three poles and the trip lever."""
    poles = merge(
        *[
            merge(
                stroke([(x, 150), (x, 380)], 66, BUTT),
                stroke([(x, 620), (x, 850)], 66, BUTT),
                circle(x, 380, 52),
                stroke([(x - 8, 392), (x + 148, 596)], 60, ROUND),
            )
            for x in (180, 480, 780)
        ]
    )
    return Ink().add(poles).add(
        stroke([(180, 470), (780, 470)], 46, ROUND, MITER, False, [64, 58])
    )


def e_stop():
    """Emergency stop: mushroom head on a collar."""
    return (
        Ink()
        .add(ring(500, 430, 320, 78))
        .add(circle(500, 430, 190))
        .add(rect(300, 770, 400, 120, 34))
        .add(box(430, 700, 570, 790))
    )


def light_curtain():
    """Safety light curtain: two columns with the beams between them."""
    beams = merge(
        *[
            stroke([(280, y), (720, y)], 52, BUTT, MITER, False, [80, 64])
            for y in (280, 420, 560, 700)
        ]
    )
    return (
        Ink()
        .add(rect(90, 130, 170, 740, 40))
        .add(rect(740, 130, 170, 740, 40))
        .add(beams)
    )


def terminal_block():
    """Terminal block: three terminals with screws and the rail foot."""
    blocks = merge(
        *[
            subtract(
                rect(x, 180, 200, 540, 28),
                merge(box(x + 56, 168, x + 144, 268, 14), circle(x + 100, 470, 56)),
            )
            for x in (110, 400, 690)
        ]
    )
    return Ink().add(blocks).add(rect(60, 760, 880, 100, 22))


def cylinder_pneumatic():
    """Pneumatic cylinder: barrel, end caps, rod, and the two ports."""
    return (
        Ink()
        .add(outline(150, 350, 700, 650, 72, 22))
        .add(box(560, 420, 632, 580))  # piston
        .add(box(632, 462, 940, 538))  # rod
        .add(rect(906, 400, 34, 200, 12))
        .add(box(214, 250, 286, 350), box(590, 250, 662, 350))
        .add(box(60, 400, 150, 600))
    )


# --- The catalogue ---------------------------------------------------------
#
# Order here is the order the glyphs are offered in the picker, and the code
# points are allocated from FIRST_CODE_POINT in this order. Append only:
# renumbering an existing glyph would silently change the artwork on every
# saved page that referenced it.

FIRST_CODE_POINT = 0xE809

#: Picker groups, in the order the editor offers them.
GROUPS = [
    ("Sensors", 9),
    ("Motors & drives", 6),
    ("Pumps & fluid handling", 8),
    ("I/O & control", 12),
]

GLYPHS = [
    # Sensors
    ("sensor_proximity", sensor_proximity),
    ("sensor_photoeye", sensor_photoeye),
    ("sensor_limit_switch", sensor_limit_switch),
    ("sensor_temperature", sensor_temperature),
    ("sensor_pressure", sensor_pressure),
    ("sensor_level", sensor_level),
    ("sensor_flow", sensor_flow),
    ("sensor_encoder", sensor_encoder),
    ("load_cell", load_cell),
    # Motors and drives
    ("motor", motor),
    ("motor_circle", motor_circle),
    ("gearmotor", gearmotor),
    ("servo_motor", servo_motor),
    ("gearbox", gearbox),
    ("vfd", vfd),
    # Pumps, valves and fluid handling
    ("pump", pump),
    ("pump_circle", pump_circle),
    ("valve", valve),
    ("valve_solenoid", valve_solenoid),
    ("valve_actuated", valve_actuated),
    ("fan", fan),
    ("compressor", compressor),
    ("tank", tank),
    # I/O, control and electrical
    ("io_module", io_module),
    ("io_digital", io_digital),
    ("io_analog", io_analog),
    ("plc", plc),
    ("hmi_panel", hmi_panel),
    ("cabinet", cabinet),
    ("power_supply", power_supply),
    ("circuit_breaker", circuit_breaker),
    ("e_stop", e_stop),
    ("light_curtain", light_curtain),
    ("terminal_block", terminal_block),
    ("cylinder_pneumatic", cylinder_pneumatic),
]


def build() -> dict[str, tuple[int, Ink]]:
    return {
        name: (FIRST_CODE_POINT + i, draw())
        for i, (name, draw) in enumerate(GLYPHS)
    }


def _dart_name(name: str) -> str:
    head, *tail = name.split("_")
    return head + "".join(part.capitalize() for part in tail)


def write_dart(path: str) -> None:
    """Emit the Dart binding for these glyphs.

    Generated rather than hand-written so a name and its code point cannot
    drift apart: the font and the map the HMI looks glyphs up in come out of
    the same list.
    """
    entries, groups, cursor = [], [], 0
    for label, count in GROUPS:
        members = GLYPHS[cursor : cursor + count]
        cursor += count
        groups.append((label, [name for name, _ in members]))
    if cursor != len(GLYPHS):
        raise SystemExit(
            f"GROUPS covers {cursor} glyphs but GLYPHS has {len(GLYPHS)}"
        )

    for i, (name, _) in enumerate(GLYPHS):
        code = FIRST_CODE_POINT + i
        entries.append(
            f"  '{name}': IconData(0x{code:04x},\n"
            f"      fontFamily: 'TfcIcons', fontPackage: 'tfc'),"
        )

    group_lines = []
    for label, names in groups:
        listed = "".join(f"\n    '{n}'," for n in names)
        group_lines.append(f"  '{label}': <String>[{listed}\n  ],")

    body = "\n".join(entries)
    grouped = "\n".join(group_lines)
    dart = f"""// GENERATED FILE -- do not edit by hand.
//
// Rebuilt by tools/icons/build.sh, which draws these glyphs into
// assets/fonts/TfcIcons.ttf and then writes this binding from the same list,
// so a name and its code point cannot drift apart.
//
// Material and Font Awesome have no motor, no VFD, no proximity sensor and no
// pump; these fill that gap for mimic pages.

import 'package:flutter/widgets.dart';

/// Every industrial glyph, by the name it serialises as, in picker order.
const Map<String, IconData> industrialIcons = <String, IconData>{{
{body}
}};

/// The picker's section headings, and which glyphs sit under each.
const Map<String, List<String>> industrialIconGroups = <String, List<String>>{{
{grouped}
}};

/// Reverse of [industrialIcons], for serialising an [IconData] back to a name.
final Map<IconData, String> industrialIconNames = <IconData, String>{{
  for (final entry in industrialIcons.entries) entry.value: entry.key,
}};
"""
    with open(path, "w") as fh:
        fh.write(dart)
    print(f"wrote {path} ({len(GLYPHS)} glyphs)")


def main() -> None:
    font_path = sys.argv[1] if len(sys.argv) > 1 else "assets/fonts/TfcIcons.ttf"
    dart_path = sys.argv[2] if len(sys.argv) > 2 else "lib/converter/industrial_icons.dart"
    glyphs = build()
    merge_into_font(font_path, glyphs)
    write_dart(dart_path)
    print(f"merged {len(glyphs)} glyphs into {font_path}")
    for name, (code, _) in glyphs.items():
        print(f"  U+{code:04X}  {name}")


if __name__ == "__main__":
    main()
