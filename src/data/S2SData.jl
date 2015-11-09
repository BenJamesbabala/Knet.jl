"""

S2SData(data1, data2; batch=128, ftype=Float32, dense=false) creates a
data generator that can be used with an S2S model.  The source data1
and target data2 should be sequence generators, i.e. next(data1)
should deliver a vector of Ints that represent the next sequence.
This division of labor allows different file formats to be supported.

maxtoken(sgen) should give the largest integer produced by sequence
generator sgen.  Note that sequence generators do not generate eos
tokens, S2SData uses maxtoken(sgen)+1 as eos by convention.  Sequence
generators do generate unk tokens (which should be included in the
maxtoken(sgen) count).

The following transformations are performed by an S2SData generator:

* sequences are minibatched according to the batch argument.
* sequences in a minibatch padded to all be the same length.
* the source sequences are generated in reverse order.
* source tokens are presented as (x,nothing) pairs
* target tokens are presented as (x[t-1],x[t]) pairs

Example:
```
source:
The dog ran
The next sentence

target:
El perror corrio
La frase siguiente
```
order of items generated by S2SData(source, target):
```
(<s>,nothing)
(ran,nothing)
(dog,nothing)
(The,nothing)
(<s>,El)
(El,perror)
(perror,corrio)
(corrio,<s>)
(<s>,nothing)
(sentence,nothing)
(next,nothing)
(The,nothing)
(<s>,La)
(La,frase)
(frase,siguiente)
(siguiente,<s>)
```
(except each word will be represented by a one-hot vector, and with
minibatch > 1, words from multiple sentences will be concatented in 
a matrix.)

Note that the end-of-sentence markers <s> are automatically inserted
by the S2SData generator and are not present in the source or the
target.  The training will be faster if adjacent sequence lengths are
similar, but S2SData does not do any sorting, this should be done by
the sequence generators.  The S2S model switches between encoding and
decoding using y=nothing as an indicator.

"""
type S2SData; bgen1; bgen2; 
    function S2SData(sgen1, sgen2; batchsize=128, ftype=Float32, dense=false, o...)
        new(S2SBatch(sgen1, batchsize, ftype, dense),
            S2SBatch(sgen2, batchsize, ftype, dense))
    end
end

typealias S2SDataFile Union{AbstractString,Cmd}

"With two filename arguments, assume SequencePerLine format"
function S2SData(file1::S2SDataFile, file2::S2SDataFile; dict1=nothing, dict2=nothing, o...)
    isa(dict1,AbstractString) && (dict1 = readvocab(dict1))
    isa(dict2,AbstractString) && (dict2 = readvocab(dict2))
    sgen1 = SequencePerLine(file1; dict=dict1, o...)
    sgen2 = SequencePerLine(file2; dict=dict2, o...)
    S2SData(sgen1, sgen2; o...)
end

"With a single filename argument, use copy for target sequence"
function S2SData(file::S2SDataFile; dict=nothing, o...)
    isa(dict,AbstractString) && (dict = readvocab(dict))
    sgen1 = SequencePerLine(file; dict=dict, o...)
    sgen2 = SequencePerLine(file; dict=dict, o...)
    S2SData(sgen1, sgen2; o...)
end

type S2SBatch; sgen; state; batch; x; y; mask; done;
    function S2SBatch(sgen, batchsize, ftype, dense)
        if dense
            x = zeros(ftype, eos(sgen), batchsize)
            y = zeros(ftype, eos(sgen), batchsize)
        else
            x = sponehot(ftype, eos(sgen), batchsize)
            y = sponehot(ftype, eos(sgen), batchsize)
        end
        mask = zeros(Cuchar, batchsize)
        batch = Array(Any, batchsize)
        new(sgen, nothing, batch, x, y, mask, false)
    end
end

import Base: start, done, next

# the S2SData state consists of (nword, encode), where nword is the
# number of words completed in the current batch, and encode is a
# boolean indicating whether we are in the encoding phase.

function start(d::S2SData)
    d.bgen1.done = d.bgen2.done = false
    d.bgen1.state = start(d.bgen1.sgen)
    d.bgen2.state = start(d.bgen2.sgen)
    nextbatch(d.bgen1)
    nextbatch(d.bgen2)
    return (0, true)
end

# We stop when there is not enough data to fill a batch

done(d::S2SData, state)=(d.bgen1.done && d.bgen2.done)

# S2SData.next returns the next token

function next(d::S2SData, state)
    (nword, encode) = state
    encode ?
    nextencode(d.bgen1, nword) :
    nextdecode(d.bgen2, nword)
end

function nextencode(b::S2SBatch, nword)
    maxlen = 1 + maximum(map(length, b.batch))
    w = maxlen-nword            # generating in reverse
    for s=1:length(b.batch)
        n=length(b.batch[s])
        xword = (w <= n ? b.batch[s][w] : w == n+1 ? eos(b.sgen) : 0)
        setrow!(b.x, xword, s)
        b.mask[s] = (xword == 0 ? 0 : 1)
    end
    nword += 1
    nword == maxlen && (nextbatch(b); nword = 0)
    return ((b.x, nothing, b.mask), (nword, (nword>0)))
end

function nextdecode(b::S2SBatch, nword)
    maxlen = 1 + maximum(map(length, b.batch))
    for s=1:length(b.batch)
        n=length(b.batch[s])
        xword = (nword == 0 ? eos(b.sgen) : nword <= n ? b.batch[s][nword] : 0)
        yword = (nword < n ? b.batch[s][nword+1] : nword == n ? eos(b.sgen) : 0)
        setrow!(b.x, xword, s)
        setrow!(b.y, yword, s)
        b.mask[s] = (xword == 0 ? 0 : 1)
    end
    nword += 1
    nword == maxlen && (nextbatch(b); nword = 0)
    return ((b.x, b.y, b.mask), (nword, (nword==0)))
end

function nextbatch(b::S2SBatch)
    for i=1:length(b.batch)
        done(b.sgen, b.state) && (b.done=true; return)
        (s, b.state) = next(b.sgen, b.state)
        b.batch[i] = s
    end
end

# TODO: these assume one hot columns, make them more general.
setrow!(x::SparseMatrixCSC,i,j)=(i>0 ? (x.rowval[j] = i; x.nzval[j] = 1) : (x.rowval[j]=1; x.nzval[j]=0))
setrow!(x::Array,i,j)=(x[:,j]=0; i>0 && (x[i,j]=1))

# Sequence generators do not generate eos, the s2s generator does.  It
# makes it maxtoken(sgen)+1 by convention.  So maxtoken of the s2s
# generator is one more than the maxtoken of the sequence generator.

eos(sgen)=maxtoken(sgen)+1
maxtoken(s::S2SData,i)=(i==1 ? eos(s.bgen1.sgen) : i==2 ? eos(s.bgen2.sgen) : error())

function readvocab(file) # TODO: test with cmd e.g. `zcat foo.gz`
    d = Dict{Any,Int}() 
    open(file) do f
        for l in eachline(f)
            for w in split(l)
                get!(d, w, 1+length(d))
            end
        end
    end
    return d
end



### DEAD CODE:

# data1 = loadseq(file1, dict1)
# data2 = loadseq(file2, dict2)
# @assert length(data1) == length(data2)
# sorted = sortblocks(data1; batch=batch, block=block)
# data1 = data1[sorted]
# data2 = data2[sorted]
# ns = length(data1)
# batch > ns && (batch = ns; warn("Changing batchsize to $batch"))
# skip = ns % batch
# if skip > 0
#     keep = ns - skip
#     nw1 = sum(map(length, sub(data1,1:keep)))
#     nw2 = sum(map(length, sub(data2,1:keep)))
#     warn("Skipping $ns % $batch = $skip lines at the end leaving ns=$keep nw1=$nw1 nw2=$nw2.")
# end

# function sortblocks(data; batch=128, block=10)
#     perm = Int[]
#     n = length(data)
#     bb = batch*block
#     for i=1:bb:n
#         j=i+bb-1
#         j > n && (j=n)
#         pi = sortperm(sub(data,i:j), by=length)
#         append!(perm, (pi + (i-1)))
#     end
#     return perm
# end

# function loadseq(fname::AbstractString, dict=Dict{Any,Int32}())
#     data = Vector{Int32}[]
#     isempty(dict) && (dict[eosstr]=eos)
#     open(fname) do f
#         for l in eachline(f)
#             sent = Int32[]
#             for w in split(l)
#                 push!(sent, get!(dict, w, 1+length(dict)))
#             end
#             push!(data, sent)
#         end
#     end
#     info("Read $fname[ns=$(length(data)),nw=$(mapreduce(length,+,data)),nd=$(length(dict))]")
#     return data
# end

# zerocolumn(x::SparseMatrixCSC,j)=(x.nzval[j]==0)
# zerocolumn(x::Array,j)=(findfirst(sub(x,:,j))==0)

# TODO: the sequence generators should write to their internal buffers
# and we should do an explicit copy here.

# We need eos in the constructor.
# We need data in batch before first call to next.
# Somebody needs to alloc x,y

# OLD_S2S=0 
# "<s>"=>1) 
#     OLD_S2S==1 && (d["<s>"]=1)
# w == "<unk>" && continue 
# @show get(d,"<s>",nothing)
# @show get(d,"<unk>",nothing)
# @show length(d)

# (r,s) =
# (x,y,m) = r
# # println((convert(Vector{Int},m), x.rowval, y==nothing?y:y.rowval))
# (r,s)
