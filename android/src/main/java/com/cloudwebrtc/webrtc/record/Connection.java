package com.cloudwebrtc.webrtc.record;

public class Connection {
    private ConnectionType connectionType;
    private String connectionId;

    public static ConnectionType connectionTypeFromString(String type) {
        switch (type){
            case "local":
                return ConnectionType.LOCAL;
            case "mixed":
                return ConnectionType.MIXED;
        }
        throw new IllegalArgumentException("Invalid type");
    }

    public Connection(ConnectionType connectionType, String connectionId) {
        this.setConnectionType(connectionType);
        this.setConnectionId(connectionId);
    }

    public ConnectionType getConnectionType() {
        return connectionType;
    }

    public void setConnectionType(ConnectionType connectionType) {
        this.connectionType = connectionType;
    }

    public String getConnectionId() {
        return connectionId;
    }

    public void setConnectionId(String connectionId) {
        this.connectionId = connectionId;
    }
}
