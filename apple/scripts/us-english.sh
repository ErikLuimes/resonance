#!/bin/bash
# Resonance's text and code are US English. This fails on the British spellings
# and wording that have turned up here, in identifiers as well as text.
#
#   apple/scripts/us-english.sh
#
# Left out: Phosphor's sources outside apple/, the vendored engines, STIL's own
# words, third-party licenses and release notes already published. A few names
# stay on purpose and are allowed below.
set -euo pipefail

cd "$(dirname "$0")/../.."

STEMS='colour|favour|behaviour|neighbour|honour|flavour|centre|centring|licence|grey|cancelled|cancelling|labelled|modelled|modelling|acknowledgement|judgement|catalogue|artefact|analogue|whilst|amongst|learnt|spelt'
WORDS='(^|[^a-z])(towards|afterwards|outwards|inwards|upwards|downwards|onwards|maths)([^a-z]|$)'
PHRASES="(has|have|it's) got([^a-z]|\$)|carr(y|ies|ied|ying) on([^a-z]|\$)|straight away|way round|different to|the odd "
ISE='(capital|central|custom|final|initial|maxim|memo|minim|neutral|normal|notar|optim|organ|raster|real|recogn|sanit|serial|standard|styl|synchron|virtual|visual|character)is(e|es|ed|er|ers|ing|ation|ations)([^a-z]|$)'
PATTERN="$STEMS|$WORDS|$ISE|$PHRASES"

# Apple's names; an HTML attribute; and names people may type, which are
# accepted in either spelling.
ALLOWED='isCancelled|NSURLErrorCancelled|labelledby|\["favourites", "favorites"\]|"favorite", "favourite"\]'

found="$(git grep --untracked -nIiE "$PATTERN" -- apple design README.md .github/README.md \
    ':!apple/residfp-sys/csrc' ':!apple/release-notes/0.1.0-alpha.[1-7].md' ':!apple/site/appcast.xml' \
    ':!*Cargo.lock' ':!apple/Resonance/Acknowledgments.txt' \
    ':!apple/raycast/package.json' ':!apple/raycast/package-lock.json' \
    ':!*/Fixtures/*' ':!apple/scripts/us-english.sh' \
    | sed -E "s/$ALLOWED//g" | grep -iE "$PATTERN" || true)"

if [ -n "$found" ]; then
    echo "error: British spelling found; Resonance is US English:" >&2
    echo "$found" | cut -c1-160 >&2
    exit 1
fi
