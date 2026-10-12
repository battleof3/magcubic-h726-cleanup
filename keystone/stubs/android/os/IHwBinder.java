package android.os;
public interface IHwBinder {
    void transact(int code, HwParcel request, HwParcel reply, int flags) throws RemoteException;
}
