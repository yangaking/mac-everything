from PIL import Image, ImageDraw
import os

def create_mac_icon():
    img = Image.open('icon_source.jpg')
    
    # Crop exactly to the bounds
    left = 192
    top = 192
    right = 832
    bottom = 832
    
    cropped = img.crop((left, top, right, bottom))
    cropped = cropped.resize((1024, 1024), Image.Resampling.LANCZOS).convert('RGBA')
    
    # Apple icon corner radius is typically 22.5% of width. 1024 * 0.225 = 230
    mask = Image.new('L', (1024, 1024), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, 1024, 1024), radius=230, fill=255)
    
    # Apply the mask directly as the alpha channel
    cropped.putalpha(mask)
    
    if not os.path.exists('AppIcon.iconset'):
        os.makedirs('AppIcon.iconset')
        
    sizes = [16, 32, 128, 256, 512]
    for size in sizes:
        resized = cropped.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(f'AppIcon.iconset/icon_{size}x{size}.png')
        resized_2x = cropped.resize((size*2, size*2), Image.Resampling.LANCZOS)
        resized_2x.save(f'AppIcon.iconset/icon_{size}x{size}@2x.png')

create_mac_icon()
