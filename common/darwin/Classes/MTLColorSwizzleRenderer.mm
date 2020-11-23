/*
 *  Copyright 2018 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "MTLColorSwizzleRenderer.h"

static NSString *const shaderSource = MTL_STRINGIFY(
using namespace metal;

typedef struct {
  packed_float2 position;
  packed_float2 texcoord;
} Vertex;

typedef struct {
  float4 position[[position]];
  float2 texcoord;
} VertexIO;

vertex VertexIO vertexPassthrough(constant Vertex *verticies[[buffer(0)]],
                                  uint vid[[vertex_id]]) {
  VertexIO out;
  constant Vertex &v = verticies[vid];
  out.position = float4(float2(v.position), 0.0, 1.0);
  out.texcoord = v.texcoord;
  return out;
}

fragment half4 fragmentColorConversion(VertexIO in[[stage_in]],
                                       texture2d<half, access::sample> texture[[texture(0)]]) {
  constexpr sampler s(address::clamp_to_edge, filter::linear);

  half4 out = texture.sample(s, in.texcoord);
  return out;
});

@implementation MTLColorSwizzleRenderer

- (NSString *)shaderSource {
  return shaderSource;
}


@end
