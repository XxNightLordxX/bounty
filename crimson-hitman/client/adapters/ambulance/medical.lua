--- ambulance adapters (client): which medical resources decide when this
--- player is dead (client/main.lua's death watcher), in the order the
--- server's are tried (server/adapters/list.lua). The client asks none of
--- them anything: it only needs to know one is running.

CrimsonIntegrations.register('ambulance', 'sc-ambulance', { resource = 'sc-ambulance' })
CrimsonIntegrations.register('ambulance', 'qbx_medical', { resource = 'qbx_medical' })
