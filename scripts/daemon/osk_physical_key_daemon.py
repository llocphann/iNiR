#!/usr/bin/env python3

import asyncio
import json

from evdev import InputDevice, ecodes, list_devices

IGNORED_NAME_PARTS = ("ydotool", "virtual")
KEYBOARD_SIGNATURE = {
    ecodes.KEY_A,
    ecodes.KEY_Z,
    ecodes.KEY_ENTER,
    ecodes.KEY_SPACE,
}
DEVICE_REFRESH_INTERVAL = 5


class PhysicalKeyboardMonitor:
    def __init__(self):
        self.devices = {}
        self.tasks = {}
        self.pressed = {}
        self.last_device_count = -1

    def _is_candidate(self, dev):
        name = (dev.name or "").lower()
        if any(part in name for part in IGNORED_NAME_PARTS):
            return False

        caps = dev.capabilities()
        key_caps = set(caps.get(ecodes.EV_KEY, []))
        return KEYBOARD_SIGNATURE.issubset(key_caps)

    def _is_pressed(self, code):
        return any(code in codes for codes in self.pressed.values())

    def _emit(self, payload):
        try:
            print(json.dumps(payload, separators=(",", ":")), flush=True)
        except BrokenPipeError:
            raise SystemExit(0)

    def _emit_device_count(self):
        count = len(self.devices)
        if count == self.last_device_count:
            return
        self.last_device_count = count
        self._emit({"type": "ready", "devices": count})

    def _set_pressed(self, path, code, pressed):
        was_pressed = self._is_pressed(code)
        codes = self.pressed.setdefault(path, set())

        if pressed:
            codes.add(code)
        else:
            codes.discard(code)

        is_pressed = self._is_pressed(code)
        if was_pressed == is_pressed:
            return

        self._emit({"type": "key", "code": code, "pressed": is_pressed})

    def _sync_device_state(self, path):
        dev = self.devices.get(path)
        if dev is None:
            return False

        try:
            active_codes = set(dev.active_keys())
        except OSError:
            return False

        previous_codes = set(self.pressed.get(path, set()))
        for code in active_codes - previous_codes:
            self._set_pressed(path, code, True)
        for code in previous_codes - active_codes:
            self._set_pressed(path, code, False)
        return True

    def _remove_device(self, path, emit_releases=True):
        held_codes = set(self.pressed.pop(path, set()))

        task = self.tasks.pop(path, None)
        if task is not None:
            task.cancel()

        dev = self.devices.pop(path, None)
        if dev is not None:
            try:
                dev.close()
            except OSError:
                pass

        if not emit_releases:
            return

        for code in held_codes:
            if not self._is_pressed(code):
                self._emit({"type": "key", "code": code, "pressed": False})

    async def refresh_devices(self):
        discovered_paths = set(list_devices())

        for path in list(self.devices.keys()):
            task = self.tasks.get(path)
            if path not in discovered_paths or task is None or task.done():
                self._remove_device(path)

        for path in list(self.devices.keys()):
            if not self._sync_device_state(path):
                self._remove_device(path)

        for path in sorted(discovered_paths):
            if path in self.devices:
                continue

            try:
                dev = InputDevice(path)
            except OSError:
                continue

            try:
                if not self._is_candidate(dev):
                    dev.close()
                    continue
            except OSError:
                dev.close()
                continue

            self.devices[path] = dev
            self.pressed[path] = set()
            self._sync_device_state(path)
            self.tasks[path] = asyncio.create_task(self.monitor_device(path))

        self._emit_device_count()

    async def monitor_device(self, path):
        dev = self.devices[path]
        try:
            async for event in dev.async_read_loop():
                if event.type != ecodes.EV_KEY:
                    continue
                if event.value == 1:
                    self._set_pressed(path, event.code, True)
                elif event.value == 0:
                    self._set_pressed(path, event.code, False)
        except asyncio.CancelledError:
            return
        except OSError:
            return

    async def run(self):
        while True:
            await self.refresh_devices()
            await asyncio.sleep(DEVICE_REFRESH_INTERVAL)

    async def close(self):
        tasks = list(self.tasks.values())
        for path in list(self.devices.keys()):
            self._remove_device(path, emit_releases=False)

        for task in tasks:
            try:
                await task
            except asyncio.CancelledError:
                pass


def main():
    monitor = PhysicalKeyboardMonitor()

    async def run():
        try:
            await monitor.run()
        finally:
            await monitor.close()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
