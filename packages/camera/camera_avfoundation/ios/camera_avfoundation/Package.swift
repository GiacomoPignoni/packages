// swift-tools-version: 5.9

// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import PackageDescription

let package = Package(
  name: "camera_avfoundation",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(
      name: "camera-avfoundation", targets: ["camera_avfoundation"])
  ],
  dependencies: [],
  targets: [
    // Headers-only C target holding the types shared between the Swift
    // renderer and the Metal shaders (uniform struct, format constants,
    // texture slots). The .metal file includes the header by relative path;
    // Swift imports this module.
    .target(
      name: "camera_avfoundation_shader_types",
      path: "Sources/camera_avfoundation_shader_types"
    ),
    .target(
      name: "camera_avfoundation",
      dependencies: ["camera_avfoundation_shader_types"],
      path: "Sources/camera_avfoundation",
      resources: [
        .process("Resources")
      ]
    ),
  ]
)
