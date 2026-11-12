# Third-party notices

## Ride Relay (protocol encoders)

RideCore's TBT frame and general-status encoders are derived from Ride Relay
(https://github.com/manov-ik/ride-relay, commit 530632e4ae116645a16710a15f73e492159a7699).

```
MIT License

Copyright (c) 2026 Mano K

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Open Location Code (plus-code decoder and test data)

`OpenLocationCode` in RideCore ports the decoder and validity rules of the reference
implementation, and the test target bundles its `decoding.csv` / `validityTests.csv`
(https://github.com/google/open-location-code, commit 83986da0156bbf51fba33d0327d8ca4b7f955c89).
Copyright Google LLC, licensed under the Apache License, Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0).
