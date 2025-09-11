bench=$1
warmup=$2
runs=$3
data=$4

echo hyperfine --warmup $warmup --runs=$runs "zig-out/bin/ghostty-bench +$bench --data=$data --mode=uucode" "zig-out/bin/ghostty-bench-old +$bench --data=$data --mode=uucode"
hyperfine --warmup $warmup --runs=$runs "zig-out/bin/ghostty-bench +$bench --data=$data --mode=uucode" "zig-out/bin/ghostty-bench-old +$bench --data=$data --mode=uucode"
