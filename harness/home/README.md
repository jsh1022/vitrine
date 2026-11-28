# Home layout geometry check

This Mac-side check compiles the same pure pill-clamping and page-tint geometry helpers used by
`Redesigned/Home/HomeHeader.x`. It covers a stale pill position across portrait/landscape widths and
confirms the tint frame takes the current page width.

```sh
clang -Wall -Wextra -Werror -framework CoreGraphics layout-check.c -o /tmp/home-layout-check
/tmp/home-layout-check
```
