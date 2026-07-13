import { retailApi } from './api';

describe('retailApi', () => {
  afterEach(() => jest.restoreAllMocks());

  test('addCartItem calls the real add-item endpoint', async () => {
    const fetchMock = jest.spyOn(global, 'fetch').mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        cart: { id: 'CART-1', storeId: 'store-river', createdAt: '', items: [] },
        correlationId: 'CORR-1',
      }),
    } as Response);

    await retailApi.addCartItem('CART-1', 'product-apples', 1);

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/carts/CART-1/items',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ productId: 'product-apples', quantity: 1 }),
      }),
    );
  });

  test('createOrder uses the same-origin API', async () => {
    const fetchMock = jest.spyOn(global, 'fetch').mockResolvedValue({
      ok: true,
      status: 201,
      json: async () => ({ order: {}, correlationId: 'CORR-2' }),
    } as Response);

    await retailApi.createOrder('CART-2');

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/orders',
      expect.objectContaining({ method: 'POST' }),
    );
  });
});
