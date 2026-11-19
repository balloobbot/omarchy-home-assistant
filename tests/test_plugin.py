"""Regression tests: python3 -I tests/test_plugin.py (from the plugin folder)."""

import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

import ha  # noqa: E402

MARKUP = '<img src="https://example.invalid/tracker">'


class HelperTests(unittest.TestCase):
  def test_entity_ids_reject_markup(self):
    with self.assertRaises(ha.HAError):
      ha.check_entity(MARKUP)
    with self.assertRaises(ha.HAError):
      ha.check_entity("light.kitchen; rm -rf ~")
    self.assertEqual(ha.check_entity("light.kitchen"), "light.kitchen")

  def test_server_ids_are_path_safe(self):
    for bad in ("../../etc", "a/b", "", "x" * 65):
      with self.assertRaises(ha.HAError):
        ha.check_uuid(bad)

  def test_txt_parsing_keeps_markup_as_data(self):
    txt = ha.parse_txt('"location_name=' + MARKUP.replace('"', '\\"') + '" "uuid=abc123"')
    self.assertEqual(txt["uuid"], "abc123")
    self.assertIn("<img", txt["location_name"])

  def test_urls_must_be_http(self):
    self.assertTrue(ha.valid_url("http://192.168.1.2:8123"))
    for bad in ("javascript:alert(1)", "file:///etc/passwd", "http://user:pw@host", "ftp://x"):
      self.assertFalse(ha.valid_url(bad))

  def test_clip_bounds_strings(self):
    self.assertLessEqual(len(ha.clip("x" * 1000)), ha.MAX_STR)
    self.assertNotIn("\n", ha.clip("a\nb"))

  def test_dashboard_collection_only_takes_entity_ids(self):
    found = []
    ha.collect_entities({"views": [{"cards": [{"entity": "light.a"}, {"title": MARKUP}, {"entities": ["sensor.b", MARKUP]}]}]}, found)
    self.assertEqual(found, ["light.a", "sensor.b"])


class ControlTests(unittest.TestCase):
  def test_camera_picture_path_is_strict(self):
    ok = ha.compact_state("camera.door", "idle", {"entity_picture": "/api/camera_proxy/camera.door?token=abc_DEF-1"})
    self.assertEqual(ok["picture"], "/api/camera_proxy/camera.door?token=abc_DEF-1")
    for bad in ("https://evil.example/x.jpg", "/api/camera_proxy/camera.door?token=a&x=" + MARKUP,
                "//evil.example/api/camera_proxy/camera.a?token=b", MARKUP):
      self.assertNotIn("picture", ha.compact_state("camera.door", "idle", {"entity_picture": bad}))

  def test_volume_is_bounded(self):
    self.assertEqual(ha.compact_state("media_player.amp", "on", {"volume_level": 0.35})["volume"], 0.35)
    self.assertNotIn("volume", ha.compact_state("media_player.amp", "on", {"volume_level": "loud"}))
    self.assertNotIn("volume", ha.compact_state("media_player.amp", "on", {"volume_level": 7}))

  def test_actions_are_allowlisted(self):
    for entity_id, service in (("lock.front", "open"), ("media_player.amp", "play_media"),
                               ("light.kitchen", "volume_up"), ("lock.front", MARKUP)):
      with self.assertRaises(ha.HAError):
        ha.action("abc123", entity_id, service)


class AmplifierTests(unittest.TestCase):
  def test_media_players_cannot_be_powered_off(self):
    with self.assertRaises(ha.HAError):
      ha.toggle("abc123", "media_player.amplifier")


class QmlTests(unittest.TestCase):
  def test_every_text_is_plain(self):
    """Each Text element must set textFormat: Text.PlainText (no AutoText sinks)."""
    with open(os.path.join(ROOT, "Panel.qml")) as handle:
      source = handle.read()
    for match in re.finditer(r"(?<![A-Za-z.])Text \{", source):
      depth, i = 1, match.end()
      while depth and i < len(source):
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        i += 1
      block = source[match.end():i]
      line = source.count("\n", 0, match.start()) + 1
      self.assertIn("textFormat: Text.PlainText", block, f"Panel.qml:{line} Text without PlainText")


if __name__ == "__main__":
  unittest.main(verbosity=1)
