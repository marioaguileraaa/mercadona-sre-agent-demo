import { render, screen } from '@testing-library/react';
import App from './App';
import { retailApi } from './services/api';

jest.mock('./services/api', () => ({
  retailApi: {
    getStores: jest.fn(),
    getProducts: jest.fn(),
    createCart: jest.fn(),
    addCartItem: jest.fn(),
    createOrder: jest.fn(),
    getTracking: jest.fn(),
  },
}));

test('renders the persistent synthetic disclaimer and text wordmark', async () => {
  (retailApi.getStores as jest.Mock).mockResolvedValue([]);

  render(<App />);

  expect(await screen.findByText('Mercadona Reliability Lab')).toBeInTheDocument();
  expect(screen.getAllByText(/Fictional technical SRE demo/)).toHaveLength(2);
  expect(screen.getAllByText(/Not an official Mercadona system/)).toHaveLength(2);
});
