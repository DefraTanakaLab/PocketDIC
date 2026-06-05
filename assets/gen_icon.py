from PIL import Image, ImageDraw, ImageFilter
import math

def blob(draw, cx, cy, rx, ry, angle_deg, color, n=24):
    a = math.radians(angle_deg)
    ca, sa = math.cos(a), math.sin(a)
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n
        f = 1 + 0.20*math.sin(2*t+0.4) + 0.13*math.sin(5*t+1.1) + 0.07*math.sin(9*t+2.3)
        ex = rx * f * math.cos(t)
        ey = ry * f * math.sin(t)
        pts.append((cx + ex*ca - ey*sa, cy + ex*sa + ey*ca))
    draw.polygon(pts, fill=color)

S = 1024
img = Image.new('RGBA', (S, S), (255, 255, 255, 255))
d = ImageDraw.Draw(img)
B = (18, 18, 18, 255)

main = [
    (155, 195, 148, 112, 18),
    (430, 135, 128,  82, -8),
    (715, 215, 155, 112, 28),
    (875, 425, 108, 142, -22),
    (565, 425, 142, 105,  8),
    (295, 495, 115,  88, -38),
    (155, 675,  92, 125, 28),
    (455, 725, 138,  98, -18),
    (735, 695, 122,  95, 20),
]
small = [
    (345, 248, 44, 36, 12),
    (775, 555, 50, 40, -18),
    (195, 408, 38, 32, 22),
    (645, 675, 36, 44, -22),
    (895, 195, 32, 26,  5),
    (510, 280, 28, 22, -10),
    (820, 740, 30, 24, 15),
]

for cx, cy, rx, ry, angle in main:
    blob(d, cx, cy, rx, ry, angle, B)
for cx, cy, rx, ry, angle in small:
    blob(d, cx, cy, rx, ry, angle, B)

img = img.filter(ImageFilter.GaussianBlur(radius=2.5))
img.save(r'C:\tools\dic_app\assets\icon.png')
print("icon saved: 1024x1024")
