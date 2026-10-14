#!/bin/bash

INPUT_DIR="testOut/noise/out"
OUTPUT_DIR="testOut/noise/jpeg"

mkdir -p "$OUTPUT_DIR"

for input_file in "$INPUT_DIR"/*.pgm; do
    # Skip if there are no .pgm files
    [ -e "$input_file" ] || continue

    filename="$(basename "$input_file" .pgm)"
    output_file="$OUTPUT_DIR/$filename.jpeg"

    echo "Converting: $input_file -> $output_file"

    convert "$input_file" "$output_file"
done