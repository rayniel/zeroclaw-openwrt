int main(void) {
    volatile double value = 1.5;
    return value * 2.0 == 3.0 ? 0 : 1;
}
