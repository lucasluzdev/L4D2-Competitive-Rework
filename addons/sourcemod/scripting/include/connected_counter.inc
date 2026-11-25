public SharedPlugin __pl_connected_counter = 
{
    name = "connected_counter",
    file = "connected_counter.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_connected_counter_SetNTVOptional()
{
    MarkNativeAsOptional("ConnectedCounter_GetConnected");
}
#endif

/**
 * @brief Called when a new human client connected
 *
 * @param userid		userid of the client
 * @param count         count of connected human userids, include the "userid" param
 * @param userids       array of connected human userids, include the "userid" param
 *
 * @noreturn
 */
forward void ConnectedCounter_OnConnected(int userid, int count, const int userids[MAXPLAYERS]);

/**
 * @brief Called when a human client is disconnecting
 *
 * @param userid		userid of the client
 * @param count         count of connected human userids, exclude the "userid" param
 * @param userids       array of connected human userids, exclude the "userid" param
 * @param reason        reason the player left the server
 * @param name          player name
 * @param networkid     player network (i.e steam) id 
 *
 * @noreturn
 */
forward void ConnectedCounter_OnDisconnect(int userid, int count, const int userids[MAXPLAYERS], const char[] reason, const char[] name, const char[] networkid);

/**
 * @brief Get the connected human userids count and array
 *
 * @param count		    buffer to store connected human userids count (optional)
 * @param userids       buffer to store connected human userids array (optional)
 *
 * @noreturn
 */
native void ConnectedCounter_GetConnected(int& count = 0, int userids[MAXPLAYERS] = {0, ...});
