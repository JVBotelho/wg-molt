BEGIN { RS="{" }
index($0, "\"pubkey\":\"" pk "\"") {
    match($0, /"id":"[^"]+"/)
    if (RSTART > 0) {
        print substr($0, RSTART+6, RLENGTH-7)
    }
}
