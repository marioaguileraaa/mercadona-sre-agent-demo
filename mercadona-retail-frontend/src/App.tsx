import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Badge,
  Box,
  Button,
  Card,
  Chip,
  CircularProgress,
  Container,
  CssBaseline,
  Divider,
  Grid,
  IconButton,
  InputAdornment,
  Paper,
  Skeleton,
  Stack,
  TextField,
  ThemeProvider,
  Tooltip,
  Typography,
  createTheme,
} from '@mui/material';
import AddIcon from '@mui/icons-material/Add';
import ArrowForwardIcon from '@mui/icons-material/ArrowForward';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import ChevronRightIcon from '@mui/icons-material/ChevronRight';
import LocalShippingOutlinedIcon from '@mui/icons-material/LocalShippingOutlined';
import LocationOnOutlinedIcon from '@mui/icons-material/LocationOnOutlined';
import SearchIcon from '@mui/icons-material/Search';
import ShoppingBasketOutlinedIcon from '@mui/icons-material/ShoppingBasketOutlined';
import StorefrontOutlinedIcon from '@mui/icons-material/StorefrontOutlined';
import brandMark from './assets/brand-mark.svg';
import heroMarket from './assets/hero-market.svg';
import applesArtwork from './assets/product-apples.svg';
import homeArtwork from './assets/product-home.svg';
import pantryArtwork from './assets/product-pantry.svg';
import produceArtwork from './assets/product-produce.svg';
import { retailApi } from './services/api';
import { Cart, Order, Product, Store, Tracking } from './types';
import './App.css';

const disclaimer =
  'Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.';

const spanishDisclaimer =
  'Demo técnica SRE ficticia. No es un sistema oficial de Mercadona. Todas las tiendas, productos, precios, cestas, pedidos, identificadores de correlación y métricas son sintéticos; no se afirma nada sobre operaciones reales.';

const productArtwork: Record<string, string> = {
  apple: applesArtwork,
  produce: produceArtwork,
  pantry: pantryArtwork,
  home: homeArtwork,
};

const categoryDetails: Record<string, { eyebrow: string; description: string; artwork: string }> = {
  'Fruta y verdura': {
    eyebrow: 'Fresco cada día',
    description: 'Fruta y verdura de nuestro catálogo ficticio.',
    artwork: produceArtwork,
  },
  Despensa: {
    eyebrow: 'Fondo de despensa',
    description: 'Básicos versátiles para el día a día.',
    artwork: pantryArtwork,
  },
  Hogar: {
    eyebrow: 'Hogar sencillo',
    description: 'Cuidado doméstico dentro de la demo.',
    artwork: homeArtwork,
  },
};

const currency = new Intl.NumberFormat('es-ES', {
  style: 'currency',
  currency: 'EUR',
});

const trackingStatusLabel = (status: string) =>
  status === 'Preparing' ? 'en preparación' : status.toLocaleLowerCase('es');

const trackingMessageLabel = (message: string) =>
  message === 'Synthetic order is being prepared for the demo.'
    ? 'El pedido sintético se está preparando para la demo.'
    : message;

const theme = createTheme({
  palette: {
    primary: { main: '#126B3A', dark: '#0B4F2A', light: '#E1F0E5', contrastText: '#FFFFFF' },
    secondary: { main: '#F2C94C', dark: '#C99E17', contrastText: '#1F2A24' },
    background: { default: '#F7FAF5', paper: '#FFFFFF' },
    text: { primary: '#1F2A24', secondary: '#5B685F' },
    divider: '#DDE6DE',
  },
  typography: {
    fontFamily: '"Segoe UI", Arial, sans-serif',
    h1: { fontWeight: 800, letterSpacing: '-0.045em' },
    h2: { fontWeight: 800, letterSpacing: '-0.035em' },
    h3: { fontWeight: 750, letterSpacing: '-0.025em' },
    h4: { fontWeight: 750, letterSpacing: '-0.02em' },
    h5: { fontWeight: 750 },
    h6: { fontWeight: 700 },
    button: { fontWeight: 750, textTransform: 'none' },
  },
  shape: { borderRadius: 16 },
  components: {
    MuiButton: {
      defaultProps: { disableElevation: true },
      styleOverrides: { root: { borderRadius: 999, minHeight: 44 } },
    },
    MuiCard: {
      styleOverrides: { root: { borderRadius: 20 } },
    },
  },
});

function App() {
  const [stores, setStores] = useState<Store[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [selectedStore, setSelectedStore] = useState<Store>();
  const [cart, setCart] = useState<Cart>();
  const [order, setOrder] = useState<Order>();
  const [tracking, setTracking] = useState<Tracking>();
  const [loadingStores, setLoadingStores] = useState(true);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('Elige una tienda sintética para comenzar.');
  const [error, setError] = useState('');
  const [query, setQuery] = useState('');
  const [activeCategory, setActiveCategory] = useState('All');

  const loadStores = useCallback(async () => {
    setLoadingStores(true);
    setError('');
    try {
      setStores(await retailApi.getStores());
    } catch {
      setError('No hemos podido cargar las tiendas sintéticas.');
    } finally {
      setLoadingStores(false);
    }
  }, []);

  useEffect(() => {
    loadStores();
  }, [loadStores]);

  const cartCount = useMemo(
    () => cart?.items.reduce((sum, item) => sum + item.quantity, 0) ?? 0,
    [cart],
  );

  const cartTotal = useMemo(
    () => cart?.items.reduce((sum, item) => sum + item.lineTotal, 0) ?? 0,
    [cart],
  );

  const categories = useMemo(
    () => Array.from(new Set(products.map((product) => product.category))),
    [products],
  );

  const filteredProducts = useMemo(() => {
    const normalizedQuery = query.trim().toLocaleLowerCase('es');
    return products.filter((product) => {
      const matchesCategory = activeCategory === 'All' || product.category === activeCategory;
      const matchesQuery =
        normalizedQuery.length === 0 ||
        `${product.name} ${product.category}`.toLocaleLowerCase('es').includes(normalizedQuery);
      return matchesCategory && matchesQuery;
    });
  }, [activeCategory, products, query]);

  const scrollTo = (id: string) => {
    document.getElementById(id)?.scrollIntoView?.({ behavior: 'smooth', block: 'start' });
  };

  const chooseStore = async (store: Store) => {
    setBusy(true);
    setError('');
    try {
      const [nextProducts, cartResponse] = await Promise.all([
        retailApi.getProducts(store.id),
        retailApi.createCart(store.id),
      ]);
      setSelectedStore(store);
      setProducts(nextProducts);
      setCart(cartResponse.cart);
      setOrder(undefined);
      setTracking(undefined);
      setQuery('');
      setActiveCategory('All');
      setMessage(`Tu carrito sintético está listo en ${store.name}.`);
      window.setTimeout(() => scrollTo('catalogo'), 0);
    } catch {
      setError('No hemos podido iniciar el carrito sintético.');
    } finally {
      setBusy(false);
    }
  };

  const addProduct = async (product: Product) => {
    if (!cart) {
      setError('Elige una tienda sintética antes de añadir productos.');
      return;
    }

    setBusy(true);
    setError('');
    try {
      const response = await retailApi.addCartItem(cart.id, product.id, 1);
      setCart(response.cart);
      setMessage(`${product.name} añadido. Correlación sintética: ${response.correlationId}`);
    } catch {
      setError('No hemos podido añadir el producto sintético.');
    } finally {
      setBusy(false);
    }
  };

  const checkout = async () => {
    if (!cart || cart.items.length === 0) {
      setError('Añade al menos un producto sintético antes de finalizar.');
      return;
    }

    setBusy(true);
    setError('');
    try {
      const orderResponse = await retailApi.createOrder(cart.id);
      const trackingResponse = await retailApi.getTracking(orderResponse.order.id);
      setOrder(orderResponse.order);
      setTracking(trackingResponse.tracking);
      setMessage(`Pedido sintético creado. Correlación: ${orderResponse.correlationId}`);
      window.setTimeout(() => scrollTo('pedido'), 0);
    } catch {
      setError('No hemos podido finalizar el pedido sintético.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <Box className="site-shell">
        <Box component="header" className="site-header">
          <Box className="demo-notice">
            <Container maxWidth="xl">
              <Typography variant="caption">{spanishDisclaimer}</Typography>
            </Container>
          </Box>
          <Container maxWidth="xl" className="header-main">
            <Button className="brand" onClick={() => scrollTo('inicio')} aria-label="Mercado Verde, ir al inicio">
              <img src={brandMark} alt="" className="brand-mark" />
              <span>
                <strong>Mercado Verde</strong>
                <small>Compra sintética</small>
              </span>
            </Button>

            <TextField
              className="header-search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder={selectedStore ? 'Buscar en esta tienda' : 'Elige una tienda para buscar'}
              disabled={!selectedStore}
              inputProps={{ 'aria-label': 'Buscar productos sintéticos' }}
              InputProps={{
                startAdornment: (
                  <InputAdornment position="start">
                    <SearchIcon />
                  </InputAdornment>
                ),
              }}
            />

            <Box component="nav" className="main-nav" aria-label="Navegación principal">
              <Button color="inherit" onClick={() => scrollTo('tiendas')}>Tiendas</Button>
              <Button color="inherit" onClick={() => scrollTo('categorias')} disabled={!selectedStore}>
                Categorías
              </Button>
            </Box>

            <Tooltip title="Ver carrito sintético">
              <IconButton
                className="cart-button"
                aria-label={`Ver carrito, ${cartCount} productos`}
                onClick={() => scrollTo('carrito')}
              >
                <Badge badgeContent={cartCount} color="secondary">
                  <ShoppingBasketOutlinedIcon />
                </Badge>
              </IconButton>
            </Tooltip>
          </Container>
        </Box>

        <Box component="main">
          <Container maxWidth="xl">
            <Box component="section" id="inicio" className="hero-section">
              <Box className="hero-copy">
                <Chip label="Tu mercado ficticio de confianza" color="secondary" />
                <Typography component="h1" variant="h1">
                  Lo cotidiano,
                  <br />
                  <span>mejor elegido.</span>
                </Typography>
                <Typography className="hero-description">
                  Una experiencia retail original para recorrer tiendas, descubrir productos y
                  completar un pedido totalmente sintético.
                </Typography>
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={1.5}>
                  <Button
                    variant="contained"
                    size="large"
                    endIcon={<ArrowForwardIcon />}
                    onClick={() => scrollTo('tiendas')}
                  >
                    Empezar la compra
                  </Button>
                  <Button variant="text" size="large" onClick={() => scrollTo('como-funciona')}>
                    Cómo funciona
                  </Button>
                </Stack>
                <Stack direction="row" spacing={3} className="hero-facts">
                  <span><strong>3</strong> tiendas demo</span>
                  <span><strong>100%</strong> datos sintéticos</span>
                </Stack>
              </Box>
              <Box className="hero-visual">
                <img src={heroMarket} alt="Ilustración original de una cesta con alimentos ficticios" />
                <Paper className="hero-floating-card hero-store-card">
                  <StorefrontOutlinedIcon color="primary" />
                  <span><strong>Tienda preparada</strong><small>Flujo seguro en el mismo origen</small></span>
                </Paper>
                <Paper className="hero-floating-card hero-delivery-card">
                  <LocalShippingOutlinedIcon color="primary" />
                  <span><strong>Seguimiento incluido</strong><small>Pedido completamente sintético</small></span>
                </Paper>
              </Box>
            </Box>

            <Box className="service-strip" id="como-funciona">
              <div><span>01</span><strong>Elige tienda</strong><small>Selecciona una ubicación demo</small></div>
              <div><span>02</span><strong>Llena tu cesta</strong><small>Añade productos sintéticos</small></div>
              <div><span>03</span><strong>Sigue el pedido</strong><small>Completa el checkout ficticio</small></div>
            </Box>

            <Box component="section" id="tiendas" className="content-section">
              <Box className="section-heading">
                <div>
                  <Typography className="section-kicker">Tu punto de partida</Typography>
                  <Typography variant="h2">¿Dónde quieres comprar?</Typography>
                </div>
                <Typography color="text.secondary">
                  Cada ubicación y servicio mostrado pertenece exclusivamente a esta demo.
                </Typography>
              </Box>

              {error && (
                <Alert
                  severity="error"
                  action={!stores.length ? <Button onClick={loadStores}>Reintentar</Button> : undefined}
                  sx={{ mb: 3 }}
                >
                  {error}
                </Alert>
              )}

              {loadingStores ? (
                <Grid container spacing={2.5} aria-label="Cargando tiendas sintéticas">
                  {[0, 1, 2].map((item) => (
                    <Grid size={{ xs: 12, md: 4 }} key={item}>
                      <Skeleton variant="rounded" height={210} />
                    </Grid>
                  ))}
                </Grid>
              ) : stores.length > 0 ? (
                <Grid container spacing={2.5}>
                  {stores.map((store, index) => {
                    const isSelected = selectedStore?.id === store.id;
                    return (
                      <Grid size={{ xs: 12, md: 4 }} key={store.id}>
                        <Card className={`store-card store-card-${index + 1} ${isSelected ? 'selected' : ''}`}>
                          <div className="store-card-top">
                            <span className="store-number">0{index + 1}</span>
                            {isSelected && <Chip label="Tienda activa" size="small" color="primary" />}
                          </div>
                          <LocationOnOutlinedIcon className="store-pin" />
                          <Typography variant="h5">{store.name}</Typography>
                          <Typography color="text.secondary">{store.area}</Typography>
                          <Typography variant="body2" className="store-note">{store.fulfilmentNote}</Typography>
                          <Button
                            variant={isSelected ? 'contained' : 'outlined'}
                            endIcon={<ChevronRightIcon />}
                            onClick={() => chooseStore(store)}
                            disabled={busy}
                          >
                            {isSelected ? 'Tienda seleccionada' : 'Comprar aquí'}
                          </Button>
                        </Card>
                      </Grid>
                    );
                  })}
                </Grid>
              ) : (
                <Paper className="empty-state">
                  <StorefrontOutlinedIcon />
                  <Typography variant="h5">No hay tiendas disponibles</Typography>
                  <Typography color="text.secondary">Vuelve a intentarlo para continuar con la demo.</Typography>
                  <Button variant="contained" onClick={loadStores}>Cargar de nuevo</Button>
                </Paper>
              )}
            </Box>

            {selectedStore && (
              <>
                <Box component="section" id="categorias" className="content-section category-section">
                  <Box className="section-heading">
                    <div>
                      <Typography className="section-kicker">Compra a tu manera</Typography>
                      <Typography variant="h2">Explora por categorías</Typography>
                    </div>
                    <Typography color="text.secondary">
                      Catálogo de {selectedStore.name}, creado para este escenario técnico.
                    </Typography>
                  </Box>
                  <Grid container spacing={2}>
                    {categories.map((category) => {
                      const details = categoryDetails[category];
                      const count = products.filter((product) => product.category === category).length;
                      return (
                        <Grid size={{ xs: 12, sm: 4 }} key={category}>
                          <button
                            type="button"
                            className={`category-card ${activeCategory === category ? 'active' : ''}`}
                            onClick={() => setActiveCategory(category)}
                            aria-pressed={activeCategory === category}
                          >
                            <span className="category-copy">
                              <small>{details?.eyebrow ?? 'Selección demo'}</small>
                              <strong>{category}</strong>
                              <span>{details?.description}</span>
                              <em>{count} productos</em>
                            </span>
                            <img src={details?.artwork ?? pantryArtwork} alt="" />
                          </button>
                        </Grid>
                      );
                    })}
                  </Grid>
                </Box>

                <Box component="section" id="catalogo" className="content-section catalog-section">
                  <Box className="section-heading catalog-heading">
                    <div>
                      <Typography className="section-kicker">Recién seleccionado</Typography>
                      <Typography variant="h2">Novedades para tu cesta</Typography>
                    </div>
                    <Stack direction="row" spacing={1} className="category-filters">
                      {['All', ...categories].map((category) => (
                        <Button
                          key={category}
                          variant={activeCategory === category ? 'contained' : 'outlined'}
                          size="small"
                          onClick={() => setActiveCategory(category)}
                        >
                          {category === 'All' ? 'Todo' : category}
                        </Button>
                      ))}
                    </Stack>
                  </Box>

                  <Box className="mobile-catalog-search">
                    <TextField
                      fullWidth
                      label="Buscar productos"
                      value={query}
                      onChange={(event) => setQuery(event.target.value)}
                      inputProps={{ 'aria-label': 'Buscar productos sintéticos en el catálogo' }}
                      InputProps={{
                        startAdornment: (
                          <InputAdornment position="start">
                            <SearchIcon />
                          </InputAdornment>
                        ),
                      }}
                    />
                  </Box>

                  <Grid container spacing={3} alignItems="flex-start">
                    <Grid size={{ xs: 12, lg: 9 }}>
                      {filteredProducts.length > 0 ? (
                        <Grid container spacing={2.5}>
                          {filteredProducts.map((product, index) => (
                            <Grid size={{ xs: 12, sm: 6, md: 4 }} key={product.id}>
                              <Card className="product-card">
                                <Box className="product-image">
                                  {index < 2 && <Chip label="Novedad" size="small" color="secondary" />}
                                  <img
                                    src={productArtwork[product.icon] ?? pantryArtwork}
                                    alt=""
                                    loading="lazy"
                                  />
                                </Box>
                                <Box className="product-content">
                                  <Typography className="product-category">{product.category}</Typography>
                                  <Typography variant="h6">{product.name}</Typography>
                                  <Typography color="text.secondary" variant="body2">{product.unit}</Typography>
                                  <Box className="product-action">
                                    <Typography className="product-price">
                                      {currency.format(product.price)}
                                    </Typography>
                                    <Tooltip title={`Añadir ${product.name}`}>
                                      <span>
                                        <IconButton
                                          color="primary"
                                          onClick={() => addProduct(product)}
                                          disabled={busy}
                                          aria-label={`Añadir ${product.name} al carrito`}
                                        >
                                          <AddIcon />
                                        </IconButton>
                                      </span>
                                    </Tooltip>
                                  </Box>
                                </Box>
                              </Card>
                            </Grid>
                          ))}
                        </Grid>
                      ) : (
                        <Paper className="empty-state compact">
                          <SearchIcon />
                          <Typography variant="h5">No encontramos coincidencias</Typography>
                          <Typography color="text.secondary">
                            Prueba otra búsqueda o vuelve a ver todo el catálogo sintético.
                          </Typography>
                          <Button onClick={() => { setQuery(''); setActiveCategory('All'); }}>
                            Ver todos los productos
                          </Button>
                        </Paper>
                      )}
                    </Grid>

                    <Grid size={{ xs: 12, lg: 3 }}>
                      <Paper component="aside" id="carrito" className="cart-panel" aria-labelledby="cart-title">
                        <Box className="cart-title-row">
                          <div>
                            <Typography className="section-kicker">Tu selección</Typography>
                            <Typography id="cart-title" variant="h4">Mi cesta</Typography>
                          </div>
                          <Badge badgeContent={cartCount} color="secondary">
                            <ShoppingBasketOutlinedIcon />
                          </Badge>
                        </Box>
                        <Divider />
                        <Stack spacing={1.5} className="cart-items">
                          {cart?.items.length === 0 && (
                            <Box className="cart-empty">
                              <ShoppingBasketOutlinedIcon />
                              <Typography fontWeight={700}>Tu cesta está vacía</Typography>
                              <Typography variant="body2" color="text.secondary">
                                Añade productos para continuar.
                              </Typography>
                            </Box>
                          )}
                          {cart?.items.map((item) => (
                            <Box key={item.productId} className="cart-line">
                              <span>
                                <Typography fontWeight={700}>{item.name}</Typography>
                                <Typography variant="caption" color="text.secondary">
                                  {item.quantity} × {currency.format(item.unitPrice)}
                                </Typography>
                              </span>
                              <Typography fontWeight={800}>{currency.format(item.lineTotal)}</Typography>
                            </Box>
                          ))}
                        </Stack>
                        <Divider />
                        <Box className="cart-total">
                          <Typography color="text.secondary">Total sintético</Typography>
                          <Typography variant="h5">{currency.format(cartTotal)}</Typography>
                        </Box>
                        <Button
                          fullWidth
                          variant="contained"
                          color="primary"
                          endIcon={<ArrowForwardIcon />}
                          onClick={checkout}
                          disabled={busy || !cart?.items.length}
                        >
                          Finalizar compra
                        </Button>
                        <Typography variant="caption" color="text.secondary" className="cart-caption">
                          Sin pago real. Esta finalización solo crea un pedido ficticio para la demo SRE.
                        </Typography>
                      </Paper>
                    </Grid>
                  </Grid>
                </Box>
              </>
            )}

            {order && tracking && (
              <Box component="section" id="pedido" className="content-section order-section">
                <Paper className="order-card">
                  <CheckCircleIcon className="order-success-icon" />
                  <Box>
                    <Typography className="section-kicker">Pedido sintético confirmado</Typography>
                    <Typography variant="h3">¡Tu cesta ya está en marcha!</Typography>
                    <Typography color="text.secondary">
                      Estado: {trackingStatusLabel(tracking.status)}. {trackingMessageLabel(tracking.message)}
                    </Typography>
                  </Box>
                  <Box className="order-details">
                    <span><small>Pedido</small><strong>{order.id}</strong></span>
                    <span><small>Seguimiento</small><strong>{tracking.trackingCode}</strong></span>
                    <span><small>Total</small><strong>{currency.format(order.total)}</strong></span>
                  </Box>
                </Paper>
              </Box>
            )}

            <Box className="status-region" role="status" aria-live="polite">
              {busy ? 'Procesando solicitud sintética…' : message}
            </Box>
          </Container>
        </Box>

        <Box component="footer" className="site-footer">
          <Container maxWidth="xl">
            <Box className="footer-main">
              <Box className="footer-brand">
                <img src={brandMark} alt="" />
                <div><strong>Mercado Verde</strong><span>Una identidad retail original para una demo técnica.</span></div>
              </Box>
              <Typography variant="body2">
                Tiendas → Productos → Cesta → Finalización → Pedido y seguimiento
              </Typography>
            </Box>
            <Divider />
            <Typography variant="caption" className="footer-disclaimer">{spanishDisclaimer}</Typography>
            <Typography variant="caption" className="footer-disclaimer required-disclaimer">
              {disclaimer}
            </Typography>
          </Container>
        </Box>

        {busy && (
          <Box className="busy-indicator" aria-hidden="true">
            <CircularProgress size={22} />
          </Box>
        )}
      </Box>
    </ThemeProvider>
  );
}

export default App;
