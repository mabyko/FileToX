# Unhwp equation converter

`Sources/Engine/Engines/Documents/HwpEquationConverter.swift` and the upstream
regression cases in `Tests/Engine/Documents/HwpEquationTests.swift` are adapted
from `src/equation.rs` in [iyulab/unhwp](https://github.com/iyulab/unhwp/blob/405b17e137b3ca06299dcbc8a156599ac7027e91/src/equation.rs),
commit `405b17e137b3ca06299dcbc8a156599ac7027e91`.

MIT License. Copyright (c) iyulab. The full notice is retained in the Swift source
header and [Unhwp.LICENSE](Unhwp.LICENSE). No Rust library is linked or shipped.

Local corrections: indexed `SQRT n OF x`, preserving non-OF words after roots,
separating LaTeX control words from following variables, and escaping braces used
as LEFT/RIGHT delimiters. Recursive parsing is
bounded for untrusted document input. Other unknown keywords pass through as upstream.
