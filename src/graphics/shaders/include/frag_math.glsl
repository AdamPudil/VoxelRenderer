#ifndef FRAG_MATH
#define FRAG_MATH

// b is a positive grid size. GLSL leaves % with negative operands undefined.
// Keep division and remainder operands nonnegative, even for INT_MIN.
int floorDiv(int a, int b) {
    return a >= 0 ? a / b : -1 - ((-1 - a) / b);
}

int positiveMod(int a, int b) {
    return a >= 0 ? a % b : b - 1 - ((-1 - a) % b);
}

#endif
