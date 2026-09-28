# Third-party notices

The root Unlicense applies to original M7 work. It does not waive copyright or
change license obligations for third-party software. Preserve the applicable
notices when distributing third-party code or builds that incorporate it.

The dependencies below are installed by `make deps` into `lib/` and retain their
upstream license files. M7 uses the MIT option for forge-std; its upstream
Apache-2.0 alternative remains available. Build tools and external deployed
protocols are separate projects governed by their own terms.

## OpenZeppelin Contracts 5.4.0 — MIT

Source: https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.4.0

Used by the contracts for token interfaces, ERC-20 shares, safe transfers,
reentrancy protection, and arithmetic. The following notice is reproduced from
`lib/openzeppelin-contracts/LICENSE` without modification.

```text
The MIT License (MIT)

Copyright (c) 2016-2025 Zeppelin Group Ltd

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Forge Standard Library 1.9.7 — MIT option

Source: https://github.com/foundry-rs/forge-std/tree/v1.9.7

Used by tests and deployment/maintenance scripts. The following notice is
reproduced from `lib/forge-std/LICENSE-MIT` without modification, including its
upstream typographical errors. The alternative license is in that dependency's
`LICENSE-APACHE` file.

```text
Copyright Contributors to Forge Standard Library

Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE O THE USE OR OTHER
DEALINGS IN THE SOFTWARE.R
```
