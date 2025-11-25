//+------------------------------------------------------------------+
//| SmartVotingSystem.mqh                                             |
//| Sistema de Votación Inteligente para 60% Win Rate                |
//| Copyright 2025, Advanced Trading Systems                          |
//+------------------------------------------------------------------+
#property copyright "Advanced Trading Systems 2025"
#property version   "1.00"
#property strict

#include <RegimeDetectionSystem.mqh>

//+------------------------------------------------------------------+
//| ENUMERACIONES                                                     |
//+------------------------------------------------------------------+

// Contextos de mercado
enum ENUM_MARKET_CONTEXT {
    CONTEXT_RANGING,           // Mercado lateral (ADX < 20)
    CONTEXT_TRENDING_UP,       // Tendencia alcista (ADX > 25, slope+)
    CONTEXT_TRENDING_DOWN,     // Tendencia bajista (ADX > 25, slope-)
    CONTEXT_VOLATILE,          // Alta volatilidad (ATR > p70)
    CONTEXT_CHOPPY,            // Mercado errático (ADX 15-25)
    CONTEXT_ACCUMULATION,      // Fase de acumulación institucional
    CONTEXT_UNKNOWN            // No clasificable
};

// Calidad de señales
enum ENUM_SIGNAL_QUALITY {
    QUALITY_POOR = 0,          // 0-30: Rechazar
    QUALITY_FAIR = 1,          // 31-50: Considerar con cuidado
    QUALITY_GOOD = 2,          // 51-70: Aceptable
    QUALITY_EXCELLENT = 3,     // 71-90: Muy bueno
    QUALITY_EXCEPTIONAL = 4    // 91-100: Excepcional
};

//+------------------------------------------------------------------+
//| ESTRUCTURAS                                                       |
//+------------------------------------------------------------------+

// Señal del indicador
struct IndicatorSignal {
    int indicatorID;                    // ID del indicador
    ENUM_VOTE_DIRECTION direction;      // Dirección del voto
    double rawConfidence;               // Confidence original (0-1)
    double calibratedConfidence;        // Confidence calibrada
    int qualityScore;                   // Score de calidad 0-100

    // Datos específicos del indicador
    union SignalData {
        struct SRData {
            double level;
            int quality;
            int touches;
            double distance;
            int timeframe;
        } sr;

        struct BreakoutData {
            int strength;
            bool hasRetest;
            double volumeRatio;
            double momentum;
        } breakout;

        struct InstitutionalData {
            int phase;
            bool springDetected;
            double buyPressure;
            double smIndex;
        } institutional;

        struct AccumulationData {
            int strength;
            int barCount;
            double volatilityRatio;
            double volumeAnomaly;
            double zoneCenter;
        } accumulation;
    } data;

    void Initialize() {
        indicatorID = -1;
        direction = VOTE_NEUTRAL;
        rawConfidence = 0.0;
        calibratedConfidence = 0.0;
        qualityScore = 0;
    }
};

// Contexto del mercado
struct MarketContextData {
    ENUM_MARKET_CONTEXT context;
    double adx;
    double adxSlope;
    double atr;
    double atrPercentile;
    double volatility;
    bool isTransitioning;               // INNOVACIÓN: Detecta transiciones
    double transitionConfidence;
    datetime lastUpdate;

    void Initialize() {
        context = CONTEXT_UNKNOWN;
        adx = 0.0;
        adxSlope = 0.0;
        atr = 0.0;
        atrPercentile = 0.0;
        volatility = 0.0;
        isTransitioning = false;
        transitionConfidence = 0.0;
        lastUpdate = 0;
    }
};

// Expertise histórico por contexto
struct ContextExpertise {
    int indicatorID;
    ENUM_MARKET_CONTEXT context;
    int trades;
    int wins;
    double winRate;
    double expectedWR;                  // WR esperado inicial
    bool isPrimary;
    bool isSecondary;
    datetime lastUpdate;

    // INNOVACIÓN: Auto-calibración
    double calibrationFactor;           // Factor de ajuste (0.8-1.2)
    bool needsRecalibration;

    void Initialize() {
        indicatorID = -1;
        context = CONTEXT_UNKNOWN;
        trades = 0;
        wins = 0;
        winRate = 0.50;
        expectedWR = 0.50;
        isPrimary = false;
        isSecondary = false;
        lastUpdate = 0;
        calibrationFactor = 1.0;
        needsRecalibration = false;
    }

    void UpdateWinRate(bool won) {
        trades++;
        if(won) wins++;

        // EMA del WR
        double alpha = MathMin(0.20, 1.0 / trades);
        winRate = winRate * (1 - alpha) + (won ? 1.0 : 0.0) * alpha;

        // Auto-calibración cada 20 trades
        if(trades % 20 == 0) {
            needsRecalibration = true;
            RecalibrateExpectedWR();
        }
    }

    void RecalibrateExpectedWR() {
        if(trades < 20) return;

        // Ajustar expectedWR basado en realidad
        double diff = winRate - expectedWR;

        if(MathAbs(diff) > 0.10) {  // Diferencia >10%
            // Mover expectedWR hacia realidad
            expectedWR += diff * 0.30;  // 30% del camino
            calibrationFactor = winRate / expectedWR;

            Print("📊 RECALIBRACIÓN - Indicador ", indicatorID,
                  " en contexto ", EnumToString(context),
                  " | Expected: ", expectedWR * 100, "% | Real: ", winRate * 100, "%");
        }

        needsRecalibration = false;
    }

    double GetCalibratedWR() {
        return expectedWR * calibrationFactor;
    }
};

//+------------------------------------------------------------------+
//| CLASE: ContextDetector                                           |
//| Detecta el contexto actual del mercado                           |
//+------------------------------------------------------------------+
class ContextDetector {
private:
    string m_symbol;
    ENUM_TIMEFRAMES m_timeframe;
    int m_adxHandle;
    int m_atrHandle;
    double m_atrHistory[100];
    int m_historyIndex;
    MarketContextData m_currentContext;
    MarketContextData m_previousContext;

    // INNOVACIÓN: Transition detector
    int m_transitionCount;
    datetime m_lastTransitionTime;

public:
    ContextDetector() {
        m_symbol = Symbol();
        m_timeframe = PERIOD_M15;
        m_adxHandle = INVALID_HANDLE;
        m_atrHandle = INVALID_HANDLE;
        m_historyIndex = 0;
        m_transitionCount = 0;
        m_lastTransitionTime = 0;
        ArrayInitialize(m_atrHistory, 0.0);
        m_currentContext.Initialize();
        m_previousContext.Initialize();
    }

    ~ContextDetector() {
        if(m_adxHandle != INVALID_HANDLE) IndicatorRelease(m_adxHandle);
        if(m_atrHandle != INVALID_HANDLE) IndicatorRelease(m_atrHandle);
    }

    bool Initialize() {
        m_adxHandle = iADX(m_symbol, m_timeframe, 14);
        m_atrHandle = iATR(m_symbol, m_timeframe, 14);

        if(m_adxHandle == INVALID_HANDLE || m_atrHandle == INVALID_HANDLE) {
            Print("❌ Error inicializando ContextDetector");
            return false;
        }

        // Cargar historial ATR
        double atr[];
        if(CopyBuffer(m_atrHandle, 0, 0, 100, atr) == 100) {
            ArrayCopy(m_atrHistory, atr);
            m_historyIndex = 99;
        }

        Print("✅ ContextDetector inicializado");
        return true;
    }

    ENUM_MARKET_CONTEXT DetectContext() {
        // Actualizar datos
        UpdateMarketData();

        // Guardar contexto previo
        m_previousContext = m_currentContext;

        // Clasificar contexto
        m_currentContext.context = ClassifyContext();
        m_currentContext.lastUpdate = TimeCurrent();

        // INNOVACIÓN: Detectar transiciones
        DetectTransition();

        return m_currentContext.context;
    }

    MarketContextData GetCurrentContext() {
        return m_currentContext;
    }

    bool IsTransitioning() {
        return m_currentContext.isTransitioning;
    }

private:
    void UpdateMarketData() {
        double adxMain[], adxPlus[], adxMinus[];
        double atr[];

        // Leer ADX
        if(CopyBuffer(m_adxHandle, 0, 0, 5, adxMain) == 5) {
            m_currentContext.adx = adxMain[0];

            // Calcular slope
            m_currentContext.adxSlope = (adxMain[0] - adxMain[4]) / 4.0;
        }

        // Leer ATR
        if(CopyBuffer(m_atrHandle, 0, 0, 1, atr) == 1) {
            m_currentContext.atr = atr[0];

            // Actualizar historial
            m_historyIndex = (m_historyIndex + 1) % 100;
            m_atrHistory[m_historyIndex] = atr[0];

            // Calcular percentil
            m_currentContext.atrPercentile = CalculatePercentile(atr[0]);

            // Calcular volatilidad
            double avgPrice = (SymbolInfoDouble(m_symbol, SYMBOL_BID) +
                              SymbolInfoDouble(m_symbol, SYMBOL_ASK)) / 2.0;
            m_currentContext.volatility = (atr[0] / avgPrice) * 100.0;
        }
    }

    ENUM_MARKET_CONTEXT ClassifyContext() {
        double adx = m_currentContext.adx;
        double slope = m_currentContext.adxSlope;
        double atrP = m_currentContext.atrPercentile;

        // 1. Choppy extremo - NO OPERAR
        if(adx < 15.0) {
            return CONTEXT_CHOPPY;
        }

        // 2. Trending claro
        if(adx > 25.0) {
            if(slope > 0.5) {
                return CONTEXT_TRENDING_UP;
            } else if(slope < -0.5) {
                return CONTEXT_TRENDING_DOWN;
            }
            // ADX alto pero sin dirección clara
            return CONTEXT_VOLATILE;
        }

        // 3. Ranging
        if(adx < 20.0 && atrP < 50.0) {
            return CONTEXT_RANGING;
        }

        // 4. Volatile
        if(atrP > 70.0) {
            return CONTEXT_VOLATILE;
        }

        // 5. Zona intermedia - CHOPPY
        if(adx >= 15.0 && adx <= 25.0) {
            return CONTEXT_CHOPPY;
        }

        return CONTEXT_UNKNOWN;
    }

    double CalculatePercentile(double currentATR) {
        int count = 0;
        for(int i = 0; i < 100; i++) {
            if(m_atrHistory[i] > 0 && m_atrHistory[i] < currentATR) {
                count++;
            }
        }
        return (count / 100.0) * 100.0;
    }

    // INNOVACIÓN: Detectar transiciones de contexto
    void DetectTransition() {
        m_currentContext.isTransitioning = false;
        m_currentContext.transitionConfidence = 0.0;

        // Si el contexto cambió
        if(m_currentContext.context != m_previousContext.context &&
           m_previousContext.context != CONTEXT_UNKNOWN) {

            datetime now = TimeCurrent();

            // Confirmar que no es ruido
            if(now - m_lastTransitionTime < 3600) {  // < 1 hora
                m_transitionCount++;
            } else {
                m_transitionCount = 1;
            }

            m_lastTransitionTime = now;

            // Si hay múltiples cambios rápidos = transición inestable
            if(m_transitionCount >= 2) {
                m_currentContext.isTransitioning = true;
                m_currentContext.transitionConfidence = 0.80;

                Print("⚠️ TRANSICIÓN DETECTADA: ",
                      EnumToString(m_previousContext.context), " → ",
                      EnumToString(m_currentContext.context),
                      " (Inestable - ", m_transitionCount, " cambios)");
            } else {
                // Transición única = estable
                m_currentContext.isTransitioning = true;
                m_currentContext.transitionConfidence = 0.40;

                Print("📊 Cambio de contexto: ",
                      EnumToString(m_previousContext.context), " → ",
                      EnumToString(m_currentContext.context));
            }
        }

        // Resetear contador si pasó mucho tiempo
        if(TimeCurrent() - m_lastTransitionTime > 7200) {  // 2 horas
            m_transitionCount = 0;
        }
    }
};

//+------------------------------------------------------------------+
//| CLASE: ExpertiseMatrix                                           |
//| Almacena el WR histórico de cada indicador por contexto          |
//+------------------------------------------------------------------+
class ExpertiseMatrix {
private:
    ContextExpertise m_matrix[30];      // 6 indicadores × 5 contextos
    int m_count;

public:
    ExpertiseMatrix() {
        m_count = 0;
    }

    bool Initialize() {
        // Limpiar
        for(int i = 0; i < 30; i++) {
            m_matrix[i].Initialize();
        }
        m_count = 0;

        // RANGING - SupportResistance es experto
        AddExpertise(0, CONTEXT_RANGING, 0.68, true, false);
        AddExpertise(1, CONTEXT_RANGING, 0.62, false, true);  // Accumulation confirma

        // TRENDING UP - Breakout es experto
        AddExpertise(3, CONTEXT_TRENDING_UP, 0.65, true, false);
        AddExpertise(4, CONTEXT_TRENDING_UP, 0.58, false, true);  // Institutional confirma
        AddExpertise(2, CONTEXT_TRENDING_UP, 0.48, false, false); // Pattern complementa

        // TRENDING DOWN - Breakout es experto
        AddExpertise(3, CONTEXT_TRENDING_DOWN, 0.65, true, false);
        AddExpertise(4, CONTEXT_TRENDING_DOWN, 0.58, false, true);
        AddExpertise(2, CONTEXT_TRENDING_DOWN, 0.48, false, false);

        // ACCUMULATION - Institutional es experto
        AddExpertise(4, CONTEXT_ACCUMULATION, 0.72, true, false);
        AddExpertise(1, CONTEXT_ACCUMULATION, 0.68, false, true);  // Accumulation confirma

        // VOLATILE - Institutional es el mejor
        AddExpertise(4, CONTEXT_VOLATILE, 0.55, true, false);
        AddExpertise(0, CONTEXT_VOLATILE, 0.45, false, true);  // S/R como confirmación

        // CHOPPY - nadie es experto (no agregamos nada)

        Print("✅ ExpertiseMatrix inicializada con ", m_count, " especializaciones");
        return true;
    }

    void AddExpertise(int indicatorID, ENUM_MARKET_CONTEXT ctx, double expectedWR,
                     bool isPrimary, bool isSecondary) {
        if(m_count >= 30) return;

        m_matrix[m_count].indicatorID = indicatorID;
        m_matrix[m_count].context = ctx;
        m_matrix[m_count].expectedWR = expectedWR;
        m_matrix[m_count].winRate = expectedWR;  // Inicialmente igual
        m_matrix[m_count].isPrimary = isPrimary;
        m_matrix[m_count].isSecondary = isSecondary;
        m_matrix[m_count].trades = 0;
        m_matrix[m_count].wins = 0;
        m_matrix[m_count].calibrationFactor = 1.0;

        m_count++;
    }

    int GetPrimaryExpert(ENUM_MARKET_CONTEXT ctx) {
        for(int i = 0; i < m_count; i++) {
            if(m_matrix[i].context == ctx && m_matrix[i].isPrimary) {
                return m_matrix[i].indicatorID;
            }
        }
        return -1;
    }

    int GetSecondaryExpert(ENUM_MARKET_CONTEXT ctx) {
        for(int i = 0; i < m_count; i++) {
            if(m_matrix[i].context == ctx && m_matrix[i].isSecondary) {
                return m_matrix[i].indicatorID;
            }
        }
        return -1;
    }

    double GetExpectedWR(int indicatorID, ENUM_MARKET_CONTEXT ctx) {
        for(int i = 0; i < m_count; i++) {
            if(m_matrix[i].indicatorID == indicatorID &&
               m_matrix[i].context == ctx) {
                return m_matrix[i].GetCalibratedWR();
            }
        }
        return 0.35;  // WR bajo por defecto
    }

    void UpdateResult(int indicatorID, ENUM_MARKET_CONTEXT ctx, bool won) {
        for(int i = 0; i < m_count; i++) {
            if(m_matrix[i].indicatorID == indicatorID &&
               m_matrix[i].context == ctx) {
                m_matrix[i].UpdateWinRate(won);

                // Log si hay recalibración
                if(m_matrix[i].needsRecalibration) {
                    Print("🔧 Auto-calibración necesaria para indicador ",
                          indicatorID, " en ", EnumToString(ctx));
                }
                break;
            }
        }
    }

    bool IsExpert(int indicatorID, ENUM_MARKET_CONTEXT ctx) {
        for(int i = 0; i < m_count; i++) {
            if(m_matrix[i].indicatorID == indicatorID &&
               m_matrix[i].context == ctx) {
                return (m_matrix[i].isPrimary || m_matrix[i].isSecondary);
            }
        }
        return false;
    }

    string GetExpertiseReport(ENUM_MARKET_CONTEXT ctx) {
        string report = "📊 EXPERTISE REPORT para " + EnumToString(ctx) + ":\n";

        for(int i = 0; i < m_count; i++) {
            if(m_matrix[i].context == ctx) {
                string role = m_matrix[i].isPrimary ? "PRIMARY" :
                             m_matrix[i].isSecondary ? "SECONDARY" : "SUPPORT";

                report += StringFormat("   Indicator %d (%s): WR %.1f%% (%d trades) | Expected: %.1f%%\n",
                                      m_matrix[i].indicatorID,
                                      role,
                                      m_matrix[i].winRate * 100,
                                      m_matrix[i].trades,
                                      m_matrix[i].GetCalibratedWR() * 100);
            }
        }

        return report;
    }
};

//+------------------------------------------------------------------+
//| CLASE: QualityFilterSystem                                       |
//| Valida la calidad de señales de cada indicador                   |
//+------------------------------------------------------------------+
class QualityFilterSystem {
private:
    double m_currentATR;

public:
    QualityFilterSystem() {
        m_currentATR = 0.0;
    }

    void UpdateATR(double atr) {
        m_currentATR = atr;
    }

    // Validar señal de Support/Resistance
    bool ValidateSupportResistance(IndicatorSignal &signal) {
        // Datos específicos S/R
        int quality = signal.data.sr.quality;
        int touches = signal.data.sr.touches;
        double distance = signal.data.sr.distance;
        int timeframe = signal.data.sr.timeframe;

        // FILTRO 1: Solo niveles CRITICAL o EXTREME
        if(quality < 3) {  // 3 = CRITICAL, 4 = EXTREME
            Print("   ❌ S/R Quality Filter: Nivel no es CRITICAL/EXTREME (quality=", quality, ")");
            return false;
        }

        // FILTRO 2: Mínimo 5 toques históricos
        if(touches < 5) {
            Print("   ❌ S/R Quality Filter: Pocos toques históricos (", touches, " < 5)");
            return false;
        }

        // FILTRO 3: Distancia < 0.5 ATR
        if(distance > 0.5 * m_currentATR) {
            Print("   ❌ S/R Quality Filter: Muy lejos del nivel (", distance, " > ", 0.5 * m_currentATR, ")");
            return false;
        }

        // FILTRO 4: Timeframe >= H1
        if(timeframe < PERIOD_H1) {
            Print("   ❌ S/R Quality Filter: Timeframe muy bajo");
            return false;
        }

        Print("   ✅ S/R Quality Filter PASSED (quality=", quality, ", touches=", touches, ")");
        return true;
    }

    // Validar señal de Breakout
    bool ValidateBreakout(IndicatorSignal &signal) {
        int strength = signal.data.breakout.strength;
        bool hasRetest = signal.data.breakout.hasRetest;
        double volumeRatio = signal.data.breakout.volumeRatio;
        double momentum = signal.data.breakout.momentum;

        // FILTRO 1: Strength >= 60 (STRONG o superior)
        if(strength < 60) {
            Print("   ❌ Breakout Quality Filter: Strength insuficiente (", strength, " < 60)");
            return false;
        }

        // FILTRO 2: DEBE tener retest
        if(!hasRetest) {
            Print("   ❌ Breakout Quality Filter: Sin retest");
            return false;
        }

        // FILTRO 3: Volumen spike >= 2.5x
        if(volumeRatio < 2.5) {
            Print("   ❌ Breakout Quality Filter: Volumen insuficiente (", volumeRatio, "x < 2.5x)");
            return false;
        }

        // FILTRO 4: Momentum >= 0.5%
        if(MathAbs(momentum) < 0.005) {
            Print("   ❌ Breakout Quality Filter: Momentum bajo");
            return false;
        }

        Print("   ✅ Breakout Quality Filter PASSED (strength=", strength, ", retest=YES, vol=", volumeRatio, "x)");
        return true;
    }

    // Validar señal de Institutional
    bool ValidateInstitutional(IndicatorSignal &signal) {
        int phase = signal.data.institutional.phase;
        bool springDetected = signal.data.institutional.springDetected;
        double buyPressure = signal.data.institutional.buyPressure;
        double smIndex = signal.data.institutional.smIndex;

        // FILTRO 1: Fase NO puede ser NONE
        if(phase == 0) {  // PHASE_NONE
            Print("   ❌ Institutional Quality Filter: Fase NONE");
            return false;
        }

        // FILTRO 2: Si es ACCUMULATION, DEBE tener spring
        if(phase == 1) {  // PHASE_ACCUMULATION
            if(!springDetected) {
                Print("   ❌ Institutional Quality Filter: ACCUMULATION sin spring");
                return false;
            }

            // Buy pressure >= 60%
            if(buyPressure < 0.60) {
                Print("   ❌ Institutional Quality Filter: Buy pressure baja (", buyPressure * 100, "% < 60%)");
                return false;
            }
        }

        // FILTRO 3: Si es MARKUP/MARKDOWN, validar SMI
        if(phase == 2 || phase == 4) {  // MARKUP o MARKDOWN
            if(smIndex > 40.0 && smIndex < 60.0) {
                Print("   ❌ Institutional Quality Filter: SMI neutral (", smIndex, ")");
                return false;
            }
        }

        Print("   ✅ Institutional Quality Filter PASSED (phase=", phase, ", spring=", springDetected, ")");
        return true;
    }

    // Validar señal de Accumulation Zones
    bool ValidateAccumulation(IndicatorSignal &signal) {
        int strength = signal.data.accumulation.strength;
        int barCount = signal.data.accumulation.barCount;
        double volatilityRatio = signal.data.accumulation.volatilityRatio;
        double volumeAnomaly = signal.data.accumulation.volumeAnomaly;

        // FILTRO 1: Strength >= 8/10
        if(strength < 8) {
            Print("   ❌ Accumulation Quality Filter: Strength baja (", strength, " < 8)");
            return false;
        }

        // FILTRO 2: Mínimo 8 barras
        if(barCount < 8) {
            Print("   ❌ Accumulation Quality Filter: Pocas barras (", barCount, " < 8)");
            return false;
        }

        // FILTRO 3: Volatilidad < 0.7
        if(volatilityRatio > 0.7) {
            Print("   ❌ Accumulation Quality Filter: Volatilidad alta (", volatilityRatio, " > 0.7)");
            return false;
        }

        // FILTRO 4: Volumen anómalo >= 110%
        if(volumeAnomaly < 1.10) {
            Print("   ❌ Accumulation Quality Filter: Volumen normal (", volumeAnomaly, "x < 1.1x)");
            return false;
        }

        Print("   ✅ Accumulation Quality Filter PASSED (strength=", strength, "/10, bars=", barCount, ")");
        return true;
    }

    // Validar señal de Pattern Memory
    bool ValidatePatternMemory(IndicatorSignal &signal) {
        // PatternMemory es más flexible, solo verificar confidence
        if(signal.rawConfidence < 0.50) {
            Print("   ❌ PatternMemory Quality Filter: Confidence baja (", signal.rawConfidence * 100, "%)");
            return false;
        }

        Print("   ✅ PatternMemory Quality Filter PASSED");
        return true;
    }

    // Método principal de validación
    bool Validate(IndicatorSignal &signal) {
        switch(signal.indicatorID) {
            case 0:  return ValidateSupportResistance(signal);
            case 1:  return ValidateAccumulation(signal);
            case 2:  return ValidatePatternMemory(signal);
            case 3:  return ValidateBreakout(signal);
            case 4:  return ValidateInstitutional(signal);
            default:
                Print("   ⚠️ Quality Filter: Indicador desconocido (", signal.indicatorID, ")");
                return false;
        }
    }
};

//+------------------------------------------------------------------+
//| CLASE: ConfirmationSystem                                        |
//| Valida que las señales primarias y secundarias estén alineadas   |
//+------------------------------------------------------------------+
class ConfirmationSystem {
private:
    double m_currentATR;

public:
    ConfirmationSystem() {
        m_currentATR = 0.0;
    }

    void UpdateATR(double atr) {
        m_currentATR = atr;
    }

    bool RequireConfirmation(IndicatorSignal &primary, IndicatorSignal &secondary,
                            ENUM_MARKET_CONTEXT ctx) {
        // VALIDACIÓN BÁSICA: Direcciones deben coincidir
        if(primary.direction != secondary.direction) {
            Print("   ❌ Confirmation: Direcciones no coinciden");
            return false;
        }

        // Validación específica por contexto
        if(ctx == CONTEXT_RANGING) {
            return ValidateRangingConfirmation(primary, secondary);
        }
        else if(ctx == CONTEXT_TRENDING_UP || ctx == CONTEXT_TRENDING_DOWN) {
            return ValidateTrendingConfirmation(primary, secondary);
        }
        else if(ctx == CONTEXT_ACCUMULATION) {
            return ValidateAccumulationConfirmation(primary, secondary);
        }

        // Para otros contextos, solo verificar direcciones
        Print("   ✅ Confirmation: Direcciones alineadas");
        return true;
    }

private:
    bool ValidateRangingConfirmation(IndicatorSignal &sr, IndicatorSignal &acc) {
        // S/R y Accumulation deben estar cerca
        double srLevel = sr.data.sr.level;
        double accCenter = acc.data.accumulation.zoneCenter;
        double distance = MathAbs(srLevel - accCenter);

        if(distance > 0.3 * m_currentATR) {
            Print("   ❌ Ranging Confirmation: S/R y Accumulation muy separados (", distance, " > ", 0.3 * m_currentATR, ")");
            return false;
        }

        // Accumulation NO debe mostrar breakout inminente
        if(acc.data.accumulation.volumeAnomaly > 1.5) {
            Print("   ❌ Ranging Confirmation: Accumulation con volumen de breakout");
            return false;
        }

        Print("   ✅ Ranging Confirmation: S/R y Accumulation alineados");
        return true;
    }

    bool ValidateTrendingConfirmation(IndicatorSignal &brk, IndicatorSignal &inst) {
        // Fase institucional debe alinearse con dirección
        int phase = inst.data.institutional.phase;

        if(brk.direction == VOTE_BUY && phase != 2) {  // PHASE_MARKUP = 2
            Print("   ❌ Trending Confirmation: Breakout UP pero Institutional no está en MARKUP");
            return false;
        }

        if(brk.direction == VOTE_SELL && phase != 4) {  // PHASE_MARKDOWN = 4
            Print("   ❌ Trending Confirmation: Breakout DOWN pero Institutional no está en MARKDOWN");
            return false;
        }

        // Buy/Sell pressure debe ser coherente
        double buyPressure = inst.data.institutional.buyPressure;

        if(brk.direction == VOTE_BUY && buyPressure < 0.55) {
            Print("   ❌ Trending Confirmation: Breakout UP pero buy pressure baja (", buyPressure * 100, "%)");
            return false;
        }

        if(brk.direction == VOTE_SELL && buyPressure > 0.45) {
            Print("   ❌ Trending Confirmation: Breakout DOWN pero buy pressure alta (", buyPressure * 100, "%)");
            return false;
        }

        Print("   ✅ Trending Confirmation: Breakout e Institutional alineados");
        return true;
    }

    bool ValidateAccumulationConfirmation(IndicatorSignal &inst, IndicatorSignal &acc) {
        // Ambos deben detectar acumulación
        if(inst.data.institutional.phase != 1) {  // PHASE_ACCUMULATION
            Print("   ❌ Accumulation Confirmation: Institutional no ve ACCUMULATION");
            return false;
        }

        if(acc.data.accumulation.strength < 8) {
            Print("   ❌ Accumulation Confirmation: Accumulation zones débil");
            return false;
        }

        // Institutional debe tener spring
        if(!inst.data.institutional.springDetected) {
            Print("   ❌ Accumulation Confirmation: Sin spring institucional");
            return false;
        }

        Print("   ✅ Accumulation Confirmation: Institutional y Accumulation alineados");
        return true;
    }
};

//+------------------------------------------------------------------+
//| CLASE: TimingFilter                                              |
//| Filtra momentos de alta imprevisibilidad                         |
//+------------------------------------------------------------------+
class TimingFilter {
private:
    string m_symbol;
    double m_normalSpread;
    double m_spreadHistory[20];
    int m_spreadIndex;

public:
    TimingFilter() {
        m_symbol = Symbol();
        m_normalSpread = 0.0;
        m_spreadIndex = 0;
        ArrayInitialize(m_spreadHistory, 0.0);
    }

    bool Initialize() {
        // Cargar historial de spreads
        UpdateSpreadHistory();

        Print("✅ TimingFilter inicializado");
        return true;
    }

    bool PassFilter() {
        datetime now = TimeCurrent();
        int hour = TimeHour(now);
        int minute = TimeMinute(now);
        int dayOfWeek = TimeDayOfWeek(now);

        // FILTRO 1: NO operar primeros/últimos 30 min de sesión
        if(IsSessionBoundary(hour, minute)) {
            Print("   ❌ Timing Filter: Cerca de inicio/fin de sesión");
            return false;
        }

        // FILTRO 2: NO operar viernes después de 3pm
        if(dayOfWeek == 5 && hour >= 15) {
            Print("   ❌ Timing Filter: Viernes PM (después de 3pm)");
            return false;
        }

        // FILTRO 3: NO operar con spread anormal
        if(!PassSpreadFilter()) {
            return false;
        }

        Print("   ✅ Timing Filter PASSED");
        return true;
    }

private:
    bool IsSessionBoundary(int hour, int minute) {
        // Asia: 00:00-08:00 GMT
        if((hour == 0 && minute < 30) || (hour == 7 && minute >= 30)) {
            return true;
        }

        // London: 08:00-16:00 GMT
        if((hour == 8 && minute < 30) || (hour == 15 && minute >= 30)) {
            return true;
        }

        // NY: 13:00-22:00 GMT
        if((hour == 13 && minute < 30) || (hour == 21 && minute >= 30)) {
            return true;
        }

        return false;
    }

    bool PassSpreadFilter() {
        double currentSpread = SymbolInfoDouble(m_symbol, SYMBOL_ASK) -
                               SymbolInfoDouble(m_symbol, SYMBOL_BID);

        UpdateSpreadHistory();

        // Calcular spread normal (promedio)
        m_normalSpread = 0.0;
        int count = 0;
        for(int i = 0; i < 20; i++) {
            if(m_spreadHistory[i] > 0) {
                m_normalSpread += m_spreadHistory[i];
                count++;
            }
        }

        if(count > 0) {
            m_normalSpread /= count;
        }

        // Spread actual > 1.5x normal
        if(currentSpread > m_normalSpread * 1.5) {
            Print("   ❌ Timing Filter: Spread anormal (", currentSpread, " > ", m_normalSpread * 1.5, ")");
            return false;
        }

        return true;
    }

    void UpdateSpreadHistory() {
        double spread = SymbolInfoDouble(m_symbol, SYMBOL_ASK) -
                       SymbolInfoDouble(m_symbol, SYMBOL_BID);

        m_spreadHistory[m_spreadIndex] = spread;
        m_spreadIndex = (m_spreadIndex + 1) % 20;
    }
};

//+------------------------------------------------------------------+
//| INNOVACIÓN: SignalQualityScorer                                 |
//| Calcula un score de calidad 0-100 para cada señal               |
//+------------------------------------------------------------------+
class SignalQualityScorer {
public:
    int CalculateQualityScore(IndicatorSignal &signal, ENUM_MARKET_CONTEXT ctx,
                             double expectedWR) {
        int score = 0;

        // COMPONENTE 1: Expected WR (0-40 puntos)
        score += (int)(expectedWR * 40.0);

        // COMPONENTE 2: Raw Confidence (0-30 puntos)
        score += (int)(signal.rawConfidence * 30.0);

        // COMPONENTE 3: Datos específicos del indicador (0-30 puntos)
        score += CalculateIndicatorSpecificScore(signal);

        // Limitar a 0-100
        if(score > 100) score = 100;
        if(score < 0) score = 0;

        return score;
    }

    ENUM_SIGNAL_QUALITY GetQualityLevel(int score) {
        if(score >= 91) return QUALITY_EXCEPTIONAL;
        if(score >= 71) return QUALITY_EXCELLENT;
        if(score >= 51) return QUALITY_GOOD;
        if(score >= 31) return QUALITY_FAIR;
        return QUALITY_POOR;
    }

private:
    int CalculateIndicatorSpecificScore(IndicatorSignal &signal) {
        switch(signal.indicatorID) {
            case 0:  return ScoreSupportResistance(signal);
            case 1:  return ScoreAccumulation(signal);
            case 2:  return ScorePatternMemory(signal);
            case 3:  return ScoreBreakout(signal);
            case 4:  return ScoreInstitutional(signal);
            default: return 15;  // Score medio
        }
    }

    int ScoreSupportResistance(IndicatorSignal &signal) {
        int score = 0;

        // Calidad del nivel
        if(signal.data.sr.quality == 4) score += 10;      // EXTREME
        else if(signal.data.sr.quality == 3) score += 7;  // CRITICAL
        else score += 3;

        // Toques históricos
        if(signal.data.sr.touches >= 10) score += 10;
        else if(signal.data.sr.touches >= 7) score += 7;
        else if(signal.data.sr.touches >= 5) score += 5;

        // Distancia (normalizada por ATR, asumiendo ya validada)
        score += 10;  // Bonus por pasar filtro de distancia

        return score;
    }

    int ScoreAccumulation(IndicatorSignal &signal) {
        int score = 0;

        // Strength
        if(signal.data.accumulation.strength >= 9) score += 10;
        else if(signal.data.accumulation.strength >= 8) score += 7;

        // Barras
        if(signal.data.accumulation.barCount >= 12) score += 10;
        else if(signal.data.accumulation.barCount >= 8) score += 7;

        // Volatilidad baja
        if(signal.data.accumulation.volatilityRatio < 0.5) score += 10;
        else if(signal.data.accumulation.volatilityRatio < 0.7) score += 5;

        return score;
    }

    int ScorePatternMemory(IndicatorSignal &signal) {
        // PatternMemory score basado solo en confidence
        return (int)(signal.rawConfidence * 30.0);
    }

    int ScoreBreakout(IndicatorSignal &signal) {
        int score = 0;

        // Strength
        if(signal.data.breakout.strength >= 80) score += 12;
        else if(signal.data.breakout.strength >= 60) score += 8;

        // Volumen
        if(signal.data.breakout.volumeRatio >= 3.0) score += 10;
        else if(signal.data.breakout.volumeRatio >= 2.5) score += 7;

        // Retest (ya validado)
        score += 8;

        return score;
    }

    int ScoreInstitutional(IndicatorSignal &signal) {
        int score = 0;

        // Fase
        if(signal.data.institutional.phase == 2 || signal.data.institutional.phase == 4) {
            score += 12;  // MARKUP/MARKDOWN
        } else if(signal.data.institutional.phase == 1) {
            score += 10;  // ACCUMULATION
        }

        // Spring detectado
        if(signal.data.institutional.springDetected) {
            score += 10;
        }

        // Buy pressure extrema
        if(signal.data.institutional.buyPressure > 0.70 || signal.data.institutional.buyPressure < 0.30) {
            score += 8;
        }

        return score;
    }
};

//+------------------------------------------------------------------+
//| CLASE PRINCIPAL: SmartVotingSystem                              |
//| Integra todos los componentes para decisión final               |
//+------------------------------------------------------------------+
class SmartVotingSystem {
private:
    ContextDetector m_contextDetector;
    ExpertiseMatrix m_expertiseMatrix;
    QualityFilterSystem m_qualityFilter;
    ConfirmationSystem m_confirmationSystem;
    TimingFilter m_timingFilter;
    SignalQualityScorer m_qualityScorer;

    // Estadísticas
    int m_signalsGenerated;
    int m_signalsAccepted;
    int m_signalsRejectedContext;
    int m_signalsRejectedExpertise;
    int m_signalsRejectedQuality;
    int m_signalsRejectedConfirmation;
    int m_signalsRejectedTiming;

public:
    SmartVotingSystem() {
        m_signalsGenerated = 0;
        m_signalsAccepted = 0;
        m_signalsRejectedContext = 0;
        m_signalsRejectedExpertise = 0;
        m_signalsRejectedQuality = 0;
        m_signalsRejectedConfirmation = 0;
        m_signalsRejectedTiming = 0;
    }

    bool Initialize() {
        Print("═══════════════════════════════════════");
        Print("  SMART VOTING SYSTEM - Inicializando");
        Print("═══════════════════════════════════════");

        if(!m_contextDetector.Initialize()) {
            Print("❌ Error inicializando ContextDetector");
            return false;
        }

        if(!m_expertiseMatrix.Initialize()) {
            Print("❌ Error inicializando ExpertiseMatrix");
            return false;
        }

        if(!m_timingFilter.Initialize()) {
            Print("❌ Error inicializando TimingFilter");
            return false;
        }

        Print("✅ SMART VOTING SYSTEM inicializado correctamente");
        Print("═══════════════════════════════════════\n");

        return true;
    }

    bool ShouldTakeTrade(IndicatorSignal &signals[], int count, string &rejectReason) {
        m_signalsGenerated++;

        Print("\n╔════════════════════════════════════════════╗");
        Print("║   SMART VOTING SYSTEM - Evaluación        ║");
        Print("╚════════════════════════════════════════════╝");

        // NIVEL 1: Context Filter
        Print("\n[NIVEL 1] Context Filter:");
        ENUM_MARKET_CONTEXT ctx = m_contextDetector.DetectContext();
        MarketContextData contextData = m_contextDetector.GetCurrentContext();

        Print("   Contexto detectado: ", EnumToString(ctx));
        Print("   ADX: ", contextData.adx, " | Slope: ", contextData.adxSlope);
        Print("   ATR Percentile: ", contextData.atrPercentile, "%");

        if(ctx == CONTEXT_CHOPPY || ctx == CONTEXT_UNKNOWN) {
            rejectReason = "Contexto CHOPPY/UNKNOWN - no operable";
            m_signalsRejectedContext++;
            Print("   ❌ RECHAZADO: ", rejectReason);
            PrintStatistics();
            return false;
        }

        // Detectar transición
        if(contextData.isTransitioning && contextData.transitionConfidence > 0.60) {
            rejectReason = "Mercado en TRANSICIÓN (inestable)";
            m_signalsRejectedContext++;
            Print("   ❌ RECHAZADO: ", rejectReason);
            PrintStatistics();
            return false;
        }

        Print("   ✅ Context Filter PASSED");

        // Actualizar ATR en filtros
        m_qualityFilter.UpdateATR(contextData.atr);
        m_confirmationSystem.UpdateATR(contextData.atr);

        // NIVEL 2: Expertise Filter
        Print("\n[NIVEL 2] Expertise Filter:");
        int primaryExpertID = m_expertiseMatrix.GetPrimaryExpert(ctx);
        int secondaryExpertID = m_expertiseMatrix.GetSecondaryExpert(ctx);

        Print("   Experto primario: ", primaryExpertID);
        Print("   Experto secundario: ", secondaryExpertID);

        if(primaryExpertID < 0) {
            rejectReason = "No hay experto primario para este contexto";
            m_signalsRejectedExpertise++;
            Print("   ❌ RECHAZADO: ", rejectReason);
            PrintStatistics();
            return false;
        }

        // Buscar señal del experto primario
        IndicatorSignal primarySignal, secondarySignal;
        bool hasPrimary = false, hasSecondary = false;

        for(int i = 0; i < count; i++) {
            if(signals[i].indicatorID == primaryExpertID) {
                primarySignal = signals[i];
                hasPrimary = true;
            }
            if(signals[i].indicatorID == secondaryExpertID) {
                secondarySignal = signals[i];
                hasSecondary = true;
            }
        }

        if(!hasPrimary) {
            rejectReason = "Experto primario no emitió señal";
            m_signalsRejectedExpertise++;
            Print("   ❌ RECHAZADO: ", rejectReason);
            PrintStatistics();
            return false;
        }

        Print("   ✅ Expertise Filter PASSED (Primary: ", primaryExpertID, ")");

        // NIVEL 3: Quality Filter
        Print("\n[NIVEL 3] Quality Filter:");
        if(!m_qualityFilter.Validate(primarySignal)) {
            rejectReason = "Señal primaria no cumple estándares de calidad";
            m_signalsRejectedQuality++;
            PrintStatistics();
            return false;
        }

        Print("   ✅ Quality Filter PASSED");

        // NIVEL 4: Confirmation Filter
        Print("\n[NIVEL 4] Confirmation Filter:");
        if(!hasSecondary) {
            rejectReason = "Sin confirmación de indicador secundario";
            m_signalsRejectedConfirmation++;
            Print("   ⚠️ RECHAZADO: ", rejectReason);
            PrintStatistics();
            return false;
        }

        if(!m_confirmationSystem.RequireConfirmation(primarySignal, secondarySignal, ctx)) {
            rejectReason = "Señales no están alineadas";
            m_signalsRejectedConfirmation++;
            PrintStatistics();
            return false;
        }

        Print("   ✅ Confirmation Filter PASSED");

        // NIVEL 5: Timing Filter
        Print("\n[NIVEL 5] Timing Filter:");
        if(!m_timingFilter.PassFilter()) {
            rejectReason = "Timing desfavorable";
            m_signalsRejectedTiming++;
            PrintStatistics();
            return false;
        }

        Print("   ✅ Timing Filter PASSED");

        // INNOVACIÓN: Calcular Signal Quality Score
        Print("\n[INNOVACIÓN] Signal Quality Score:");
        double expectedWR = m_expertiseMatrix.GetExpectedWR(primaryExpertID, ctx);
        int qualityScore = m_qualityScorer.CalculateQualityScore(primarySignal, ctx, expectedWR);
        ENUM_SIGNAL_QUALITY qualityLevel = m_qualityScorer.GetQualityLevel(qualityScore);

        primarySignal.qualityScore = qualityScore;

        Print("   Score: ", qualityScore, "/100");
        Print("   Nivel: ", EnumToString(qualityLevel));
        Print("   Expected WR: ", expectedWR * 100, "%");

        // DECISIÓN FINAL
        m_signalsAccepted++;

        Print("\n╔════════════════════════════════════════════╗");
        Print("║   ✅ TODOS LOS FILTROS PASADOS             ║");
        Print("║   TRADE ACEPTADO                           ║");
        Print("╚════════════════════════════════════════════╝");
        Print("   Contexto: ", EnumToString(ctx));
        Print("   Experto: ", primaryExpertID);
        Print("   Dirección: ", EnumToString(primarySignal.direction));
        Print("   Quality Score: ", qualityScore, "/100");
        Print("   Expected WR: ", expectedWR * 100, "%");
        Print("");

        PrintStatistics();
        return true;
    }

    void UpdateResult(int indicatorID, ENUM_MARKET_CONTEXT ctx, bool won) {
        m_expertiseMatrix.UpdateResult(indicatorID, ctx, won);
    }

    string GetExpertiseReport(ENUM_MARKET_CONTEXT ctx) {
        return m_expertiseMatrix.GetExpertiseReport(ctx);
    }

    MarketContextData GetCurrentContext() {
        return m_contextDetector.GetCurrentContext();
    }

private:
    void PrintStatistics() {
        int total = m_signalsGenerated;
        if(total == 0) return;

        double acceptanceRate = (m_signalsAccepted / (double)total) * 100.0;

        Print("\n📊 ESTADÍSTICAS DEL FILTRADO:");
        Print("   Señales generadas: ", total);
        Print("   Señales aceptadas: ", m_signalsAccepted, " (", acceptanceRate, "%)");
        Print("   Rechazadas - Context: ", m_signalsRejectedContext);
        Print("   Rechazadas - Expertise: ", m_signalsRejectedExpertise);
        Print("   Rechazadas - Quality: ", m_signalsRejectedQuality);
        Print("   Rechazadas - Confirmation: ", m_signalsRejectedConfirmation);
        Print("   Rechazadas - Timing: ", m_signalsRejectedTiming);
        Print("");
    }
};

//+------------------------------------------------------------------+

#endif

