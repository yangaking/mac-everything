from PIL import Image
import numpy as np

img = Image.open('icon_source.jpg').convert('RGB')
arr = np.array(img)

# The dark icon is in the center. Let's find the bounding box where pixels are dark.
# Background has windows, dock, etc. The dark icon has R, G, B mostly < 100.
# Let's threshold the image: dark pixels are True
dark_mask = (arr[:,:,0] < 120) & (arr[:,:,1] < 120) & (arr[:,:,2] < 150)

# Find rows and cols that have a significant number of dark pixels
row_sums = np.sum(dark_mask, axis=1)
col_sums = np.sum(dark_mask, axis=0)

# Threshold: at least 200 dark pixels to be considered part of the icon
row_indices = np.where(row_sums > 200)[0]
col_indices = np.where(col_sums > 200)[0]

top = row_indices[0]
bottom = row_indices[-1]
left = col_indices[0]
right = col_indices[-1]

print(f"Detected bounds: left={left}, top={top}, right={right}, bottom={bottom}")
print(f"Width={right-left}, Height={bottom-top}")
