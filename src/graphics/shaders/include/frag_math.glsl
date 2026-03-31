#ifndef FRAG_MATH
#define FRAG_MATH

int floorDiv(int a, int b) {
    int q = a / b;
    int r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) q -= 1;
    return q;
}

int positiveMod(int a, int b) {
    int m = a % b;
    return (m < 0) ? (m + b) : m;
}

#endif