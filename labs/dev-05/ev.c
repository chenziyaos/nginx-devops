/*
 * dev-05: the sizes behind the worker's startup allocations. Linked against the objects of
 * the pinned build (see labs/ctest.sh).
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_event.h>


int
main(void)
{
    printf("sizeof(ngx_connection_t)=%zu, sizeof(ngx_event_t)=%zu\n",
           sizeof(ngx_connection_t), sizeof(ngx_event_t));
    printf("x 512 connections: %zu and %zu bytes\n",
           512 * sizeof(ngx_connection_t), 512 * sizeof(ngx_event_t));

    return 0;
}
