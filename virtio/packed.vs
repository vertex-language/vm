package virtio

// Packed virtqueues (spec §2.8, VIRTIO_F_RING_PACKED): one descriptor ring
// with wrap counters instead of three split areas. Fewer cache lines per
// request, and what newer drivers prefer.
//
// TODO(P3): PackedQueue with the same Pop / Push / ReadAll / WriteAll as
// Queue, and Queue becoming a protocol both conform to. Until then no
// device offers Feature.ringPacked.
