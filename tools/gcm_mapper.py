#!/usr/bin/env python3
"""
GCM (Graphic Control Measures) mapper.

Loads YAML mapping config and provides prefix-based CoT type classification.
"""

from __future__ import annotations

import os
import yaml


class GcmMapper:
    """Load GCM mapping YAML and classify CoT event types."""

    def __init__(self, mapping_path: str):
        self.mapping_path = mapping_path
        self.layers = {}
        self.settings = {}
        self.exclude_types = []
        self.deduplicate_by_uid = False
        self._load()

    def _load(self):
        if not os.path.isfile(self.mapping_path):
            raise FileNotFoundError(f"Mapping file not found: {self.mapping_path}")

        with open(self.mapping_path, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}

        self.layers = data.get("layers") or {}
        self.settings = data.get("settings") or {}
        self.exclude_types = self.settings.get("exclude_types") or []
        self.deduplicate_by_uid = bool(self.settings.get("deduplicate_by_uid", False))

    def classify(self, event_type: str) -> str | None:
        """Return GCM layer name for a CoT type, or None if excluded/unknown."""
        if not event_type:
            return None

        for prefix in self.exclude_types:
            if event_type.startswith(prefix):
                return None

        for layer_name, cfg in self.layers.items():
            for prefix in cfg.get("cot_types", []) or []:
                if event_type.startswith(prefix):
                    return layer_name

        return None

    def get_layer_config(self, layer_name: str) -> dict:
        """Return mapping config for the named layer."""
        return self.layers.get(layer_name, {})
