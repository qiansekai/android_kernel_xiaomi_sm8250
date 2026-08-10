import re, sys

path = 'KernelSU/kernel/selinux/selinux.c'
with open(path, 'r') as f:
    c = f.read()

old_var = 'u32 susfs_ksu_sid = 0;'
new_var = 'u32 susfs_ksu_sid = 0;\nu32 susfs_lsposed_file_sid = 0;'
if old_var in c and 'susfs_lsposed_file_sid' not in c:
    c = c.replace(old_var, new_var, 1)
    print('[+] lsposed_file SID variable added')
else:
    print('[-] lsposed_file SID variable already exists or not found')

old_cache = '    susfs_ksu_sid = cached_su_sid;'
new_cache = '    susfs_ksu_sid = cached_su_sid;\n    err = security_secctx_to_secid("u:object_r:lsposed_file:s0", strlen("u:object_r:lsposed_file:s0"), &susfs_lsposed_file_sid);\n    if (err) {\n        pr_warn("Failed to cache lsposed_file SID: %d\\n", err);\n        susfs_lsposed_file_sid = 0;\n    } else {\n        pr_info("Cached lsposed_file SID: %u\\n", susfs_lsposed_file_sid);\n    }'
if old_cache in c and 'lsposed_file' not in c[c.find(old_cache):c.find(old_cache) + 200]:
    c = c.replace(old_cache, new_cache, 1)
    print('[+] lsposed_file SID cache added')
else:
    print('[-] lsposed_file SID cache already exists or not found')

with open(path, 'w') as f:
    f.write(c)
