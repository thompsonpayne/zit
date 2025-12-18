Me learning zig 0.15.2

<h1>Prerequisite</h1>
<p>zig 0.15.2</p>
<p>Branch: master</p>

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
