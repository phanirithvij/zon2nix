readAllAlloc, bufferedreader are all extremely slower than go

I have a file here, . which with golang it finishes in less than 100ms. but with
zig takes forever, consistently. what can I do to improve the read speed?

I create a 1gb sample file
`dd if=/dev/urandom of=sample.bin bs=1G count=1 iflag=fullblock`

file.reader().readAllAlloc/readAll, bufferedreader, Read() extremely slower than
go
