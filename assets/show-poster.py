#!/usr/bin/env python3
"""Display a text poster centered (horizontally + vertically) in the terminal."""
import os
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "poster.txt"
lines = open(path, encoding="utf-8").read().rstrip("\n").split("\n")
cols, rows = os.get_terminal_size()

width = max(len(l) for l in lines)
pad_left = max(0, (cols - width) // 2)
pad_top = max(0, (rows - len(lines)) // 2)

print("\033[2J\033[H", end="")          # clear screen
print("\033[?25l", end="")               # hide cursor
print("\n" * pad_top, end="")
for l in lines:
    print(" " * pad_left + l)
print("\n" * max(0, rows - pad_top - len(lines) - 2), end="")
