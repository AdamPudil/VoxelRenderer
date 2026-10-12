#ifndef SELECTION_OUTLINE
#define SELECTION_OUTLINE

// Only draw on an actual outer face of the box. Never clamp an out-of-box
// intersection onto its edges: that would turn a whole face into an outline.
float visibleBoxEdge(vec3 point, vec3 normal, vec3 lower, float size, vec3 pixelSize) {
    vec3 local = point - lower;
    if (any(lessThan(local, vec3(-0.001))) ||
        any(greaterThan(local, vec3(size + 0.001)))) return 0.0;
    vec3 edge = min(abs(local), abs(vec3(size) - local));
    float faceDistance = dot(edge, abs(normal));
    if (faceDistance > 0.001) return 0.0;
    vec2 faceEdges = abs(normal.x) > 0.5 ? edge.yz :
                     (abs(normal.y) > 0.5 ? edge.xz : edge.xy);
    vec2 facePixelSize = abs(normal.x) > 0.5 ? pixelSize.yz :
                         (abs(normal.y) > 0.5 ? pixelSize.xz : pixelSize.xy);
    vec2 pixelDistance = faceEdges / max(facePixelSize, vec2(1e-6));
    // A one-pixel line with antialiased coverage on both sides of each edge.
    vec2 coverage = 1.0 - smoothstep(vec2(0.0), vec2(1.0), pixelDistance);
    // Fade unresolved edges when the selection becomes smaller than a few pixels.
    coverage *= smoothstep(vec2(3.0), vec2(8.0), size / max(facePixelSize, vec2(1e-6)));
    return max(coverage.x, coverage.y);
}

vec4 shadeSelectionOutline(vec3 dir, ivec3 targetVoxel, int targetValid) {
    // Evaluate derivatives before hit-dependent branches. Differentiate the ray
    // on this face's plane, avoiding discontinuities between neighboring voxels.
    vec3 dirDx = dFdx(dir);
    vec3 dirDy = dFdy(dir);
    ivec3 hitVoxel;
    vec3 normal;
    bool hit;
    vec4 color = castTraceRay(uCamPos, dir, hitVoxel, normal, hit);
    if (uIconMode || !hit || targetValid == 0 || dot(normal, normal) == 0.0) return color;
    ivec3 lower = uVoxelMode ? targetVoxel : worldToBlockLower(targetVoxel);
    ivec3 hitCell = uVoxelMode ? hitVoxel : worldToBlockLower(hitVoxel);
    if (any(notEqual(hitCell, lower))) return color;
    float size = uVoxelMode ? 1.0 : float(BLOCK_SIZE);

    vec3 face = vec3(hitVoxel) + max(normal, vec3(0.0));
    float t = dot(face - uCamPos, normal) / dot(dir, normal);
    vec3 point = uCamPos + dir * t;
    float denominator = dot(dir, normal);
    vec3 pointDx = t * (dirDx - dir * dot(dirDx, normal) / denominator);
    vec3 pointDy = t * (dirDy - dir * dot(dirDy, normal) / denominator);
    vec3 pixelSize = sqrt(pointDx * pointDx + pointDy * pointDy);
    float selectionLine = visibleBoxEdge(point, normal, vec3(lower), size, pixelSize);
    // Only the selected cell receives a black outline; first hits hide occluded edges.
    color.rgb = mix(color.rgb, vec3(0.0), selectionLine);
    return color;
}

#endif
