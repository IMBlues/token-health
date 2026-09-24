import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image, ImageDraw


spec = importlib.util.spec_from_file_location("icons", Path(__file__).with_name("generate-icons.py"))
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)


class IconTests(unittest.TestCase):
    def test_menu_uses_alpha_not_rgb_and_keeps_aspect(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "mark.png"
            source = Image.new("RGBA", (100, 100), (0, 0, 0, 0))
            draw = ImageDraw.Draw(source)
            draw.rectangle((10, 40, 89, 59), fill="white")
            draw.rectangle((20, 43, 35, 56), fill=(0, 0, 0, 0))
            source.save(path)
            with patch.object(icons, "ARTWORK", path):
                mark = icons.render_menu_mark(72)
            self.assertEqual(mark.mode, "RGBA")
            alpha = mark.getchannel("A")
            box = alpha.point(lambda x: 255 if x > 128 else 0).getbbox()
            self.assertGreater(box[2] - box[0], 3 * (box[3] - box[1]))
            self.assertEqual(alpha.getpixel((0, 0)), 0)
            self.assertEqual(alpha.getpixel((17, 36)), 0)
            self.assertGreater(alpha.getpixel((50, 36)), 240)

    def test_empty_transparent_art_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "empty.png"
            Image.new("RGBA", (40, 40)).save(path)
            with patch.object(icons, "ARTWORK", path):
                with self.assertRaises(ValueError):
                    icons.render_menu_mark()


if __name__ == "__main__":
    unittest.main()
