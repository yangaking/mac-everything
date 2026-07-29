from PIL import Image, ImageDraw
import os

def create_mac_icon():
    # Solid red square with alpha mask
    img = Image.new('RGBA', (1024, 1024), (255, 0, 0, 255))
    mask = Image.new('L', (1024, 1024), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, 1024, 1024), radius=230, fill=255)
    img.putalpha(mask)
    
    if not os.path.exists('AppIcon.iconset'):
        os.makedirs('AppIcon.iconset')
        
    sizes = [16, 32, 128, 256, 512]
    for size in sizes:
        resized = img.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(f'AppIcon.iconset/icon_{size}x{size}.png')
        resized_2x = img.resize((size*2, size*2), Image.Resampling.LANCZOS)
        resized_2x.save(f'AppIcon.iconset/icon_{size}x{size}@2x.png')

create_mac_icon()
