Me learning zig 0.15.2

<h1>Prerequisite</h1>
<span>zig 0.15.2</span>

<h1>Basic usage</h1>
Init a repo

```zig
zig run build -- init
```

Stage files (add)
```zig
zig run build -- add *
```

Commit
```zig
zig run build -- commit -m "commit message"
```
<h1></h1>
<p>Stage files did apply multithread for faster hashing and blobs writing.
</p>
<p>Very barebone but still progress for zig journey. </p>
